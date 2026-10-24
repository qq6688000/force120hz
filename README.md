# Force120Hz 1.0.0 — 全局 120Hz + 启动动画加速 3 倍

两个独立功能打包在一起：

1. **全局 120Hz** — 让所有 App 都跑 ProMotion 120Hz，不管它自己在 Info.plist 里有没有写 `CADisableMinimumFrameDurationOnPhone`。
2. **启动动画 x3** — SpringBoard 的 App 打开/关闭/切换过渡时长除以 3，视觉上"啪"一下就进去了。

---

## 安装

```sh
dpkg -i com.minis.force120hz_1.0.0_iphoneos-arm64.deb
```

装完 postinst 会自动 `killall -9 SpringBoard`。等桌面回来之后：

```sh
f120 status
```

必须看到这几行才算装成功：

```
== 加载标记 ==
   loaded 1.0.0 proc=SpringBoard sb=1 pid=xxxx

== SpringBoard 侧状态（含 launch-hooks 数）==
   Force120Hz 1.0.0 proc=SpringBoard sb=1 pid=xxxx
     Force120      = YES
     LaunchSpeedup = YES   divisor=3.0
     launch-hooks  = N      ← N > 0 才算加速生效
```

> `launch-hooks = 0` 表示这个 iOS 版本上候选的 `SBApp*` 类/方法都不存在，
> 加速不生效（但 120Hz 仍然生效）。把 `f120 log` 贴回来即可定位真实类名，
> 我把它加进候选表出下一版。

---

## 120Hz 的实现

**plist 用 `Filter.Mode = Any`**，所以 dylib 会被注入到**每一个进程**。`%ctor` 第一行用 `NSClassFromString(@"UIApplication")` 硬闸门挡掉所有非 UI 进程（守护进程、launchd 之类），这些进程直接 return，几乎零开销。

剩下的 UI 进程（所有 App + SpringBoard）里，装了 4 个 hook：

| Hook | 作用 |
|---|---|
| `- [UIScreen maximumFramesPerSecond]` | 返回 120。App 探测屏幕能力时直接看到 120 |
| `+ [CADisplayLink displayLinkWithTarget:selector:]` | 建完立刻把 `preferredFrameRateRange` 设成 `120/120/120`，`preferredFramesPerSecond` 设成 120 |
| `- [CADisplayLink setPreferredFrameRateRange:]` | 拦截后续任何低于 120 的请求，强制改回 `120/120/120` |
| `- [CADisplayLink setPreferredFramesPerSecond:]` | 老 API，很多 App 还在用它 cap 到 60，同样拦截 |
| `- [CAAnimation setPreferredFrameRateRange:]` | `maximum`/`preferred` 拉到 120（`minimum` 保留低值，空闲时仍能降帧省电） |

另外还有一个 best-effort 的场景级探测：在 `UISceneWillConnectNotification` 和定时器回调里，对每个 `UIWindowScene` 尝试 `setPreferredFrameRateRange:` / `_setPreferredFrameRateRange:`，**只在 `respondsToSelector:` 为真时才调用**（这两个方法在 16.5 的 UIKit 里并不存在，所以通常是 no-op，但万一某个 iOS 版本有就白赚）。

### 已知边界（这是 iOS 的限制，不是插件的 Bug）

`CADisplayLink` 的 `preferredFrameRateRange` 是**每个场景**的渲染节奏，UIKit 的 block animation 会跟着它走。但如果某个 App 的内部逻辑主动把 `CAAnimation.preferredFrameRateRange` 设成低值，而我们只 hook 了 setter 拦截——那它设进去的就是 120 了，也会被拉满。所以**动画和渲染循环都应该能到 120**。

真正可能仍然 cap 在 60 的场景：某个 App 完全不使用 `CADisplayLink`，而是靠自己内部的 C 层 `CA::DisplayLink`（绕过 ObjC），且它自己没有声明 ProMotion。这种情况 hook 不到，需要走场景级的私有 API（16.5 上不存在）。

---

## 启动动画加速的实现

SpringBoard 的 App 打开动画由 `SBApp*` 一堆类的 duration 方法决定。**每个 iOS 版本类名和方法名都会变**（`SBAppLaunchAnimationController` / `SBAppTransition` / `SBAppToAppWorkspaceTransaction` / `SBAppToHomeWorkspaceTransaction` / `SBAppActivation*` / `SBAppDeactivation*` / `SBApplicationLaunchTransition` / `SBAppLaunchTransition`…），所以这里**不用 Logos `%hook`**——Logos 会在类不存在时把方法**硬加上去**，污染系统；而且 selector 不存在时 `%orig` 是 NULL 调用会直接崩。

改用**运行时探测 + 自己写 orig IMP**：

```c
// 每个候选 (class, selector) 各自持有独立的 orig IMP
static IMP _orig_0 = NULL;
static double _lhook_0(id self, SEL _cmd) {
    double d = _orig_0 ? ((double(*)(id,SEL))_orig_0)(self,_cmd) : 0.0;
    if (gLaunchSpeedup && d > 0.0 && gLaunchDivisor > 0.0) d /= gLaunchDivisor;
    return d;
}
```

安装时逐条判断：

```c
Class c = objc_getClass("SBAppToAppWorkspaceTransaction");
SEL s   = sel_registerName("_completionDurationForContext:");
if (c && [c instancesRespondToSelector:s])
    MSHookMessageEx(c, s, (IMP)_lhook_N, &_orig_N);
```

三条安全保证：

1. **类不存在 → 跳过**。App 进程里根本没有 `SBApp*` 类，整个加速是 no-op（不用显式判断 SpringBoard，探测本身就够了）。
2. **selector 不存在 → 跳过**。不会被硬加成一个幽灵方法。
3. **每个 hook 自己持有 orig IMP**。这是关键——如果 hooked 的子类 `[super duration]`，Logos 的 `%orig` 会在 super call 时递归；独立 orig IMP 直接调用父类原始实现，不递归。

候选表在 `gen_launch.py` 里，`LaunchSpeedup.inc` 是自动生成的（CI 里跑 `python3 gen_launch.py > LaunchSpeedup.inc` 重新生成）。要加新候选类，只改 `gen_launch.py` 里的 `CANDIDATES` 列表。

加速倍数 `divisor` 存 plist 的 `LaunchDivisor`（默认 3.0，最小 1.0 = 不加速）。**改了必须 `f120 sb` 重启 SpringBoard**，因为 hook 是在 `%ctor` 里装的。

---

## 使用 `f120`

```sh
f120 status            # 一条命令看全部：配置 + 安装位置 + 加载标记 + SB 侧状态 + 日志尾部
f120 on | off          # 120Hz 总开关（写 plist + 发 reload 通知，运行时会刷一遍场景）
f120 launch on|off     # 启动动画加速开关
f120 divisor 3.0       # 加速倍数（1.0 = 不加速，3.0 = 默认）
f120 set <key> <value> # 任意键
f120 log [n]           # 看日志（默认 80 行）
f120 logclear          # 清日志
f120 sb                # 重启 SpringBoard
```

配置文件 `/var/mobile/Library/Preferences/com.minis.force120hz.plist`：

| Key | 默认 | 说明 |
|---|---|---|
| `Force120` | `true` | 120Hz 总开关 |
| `LaunchSpeedup` | `true` | 启动动画加速开关 |
| `LaunchDivisor` | `3.0` | 加速倍数（≥1.0） |
| `DebugLog` | `true` | 日志开关（200KB 环形截断） |

日志 `/var/mobile/Library/Preferences/com.minis.force120hz.log`，会打出：

- `=== Force120Hz 1.0.0 loaded in <进程名> (sb=0/1 pid=...) ===`
- `launch-hook: <类> :: <方法> (divisor=3.0)` — 每条实际装上的 hook
- `launch-speedup: N duration hooks installed`

---

## 排查

| 现象 | 原因 | 处理 |
|---|---|---|
| 加载标记缺失 | dylib 从未被执行 | 看 `ls -l /var/jb/Library/MobileSubstrate/DynamicLibraries/Force120Hz.dylib` 是不是真实文件（首字符 `-` 而不是 `l`）。是本包 2.0.2 那条 dpkg 教训：`/var/jb/usr/lib/TweakInject` 在本设备不可写，deb 里绝不含它 |
| `launch-hooks = 0` | 候选表没命中这个 iOS 版本 | `f120 log` 看是否连 loaded 都没有；有的话就是类名问题，把日志贴回来我加候选 |
| 120Hz 没效果 | 可能 App 内部用 C 层 `CA::DisplayLink` 绕过了 ObjC | 换 App 验证；能到 120 的 App 说明 hook 有效 |
| 动画太快太生硬 | divisor 太大 | `f120 divisor 2.0 && f120 sb` |

---

## 构建

GitHub Actions（`macos-15` + Theos + iPhoneOS16.5 SDK）：

```sh
export THEOS=/opt/theos
export THEOS_PACKAGE_SCHEME=rootless
python3 gen_launch.py > LaunchSpeedup.inc   # 重新生成加速 hook
make FINALPACKAGE=1
```

产物 `com.minis.force120hz_1.0.0_iphoneos-arm64.deb`，artifact 名 `force120hz-deb`。

deb 内容（**不含任何 TweakInject 路径**）：

```
DEBIAN/control, postinst, preinst
var/jb/Library/MobileSubstrate/DynamicLibraries/Force120Hz.dylib   (+plist, binary1)
var/jb/usr/bin/f120
```

TweakInject 由 postinst 在**运行时**探测：目录存在 + 可写 + `pwd -P` 与 DynamicLibraries 不同才 `cp -f`（真实文件，不用符号链接——`ln -sf X X` 曾把 dylib 毁成 67 字节自指链接）。探测失败不影响安装。

preinst 只删 `DynamicLibraries` 里的**符号链接**，绝不碰真实文件。
