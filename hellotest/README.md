# Force120Hz-HelloTest

安全测试版（canary）—— 从主 Tweak.x 同源构建，用于验证注入链路是否通。

## 与主版的区别

| | 主版 (1.3.0) | HelloTest (1.0-3) |
|---|---|---|
| Filter | `com.apple.UIKit` + `com.apple.springboard` | **相同**（1.0-3 起改为全局） |
| 用途 | 日常使用 | 验证注入是否生效 |
| 自检 | `f120` | `f120test` |
| payload | 同一份 dylib | 同一份 dylib（不同构建） |

## 文件

- `control` — dpkg 控制文件
- `postinst` — 签名 + 自检引导（不静默删 payload）
- `f120test` — 注入状态自检 CLI
- `Force120HzTest.plist` — 全局注入过滤器

## 验证注入

```sh
f120test    # 打开任意 App 后运行
```

标记文件 `/var/mobile/Library/Preferences/com.minis.force120hz.loaded`
里 `proc=` 字段显示哪些进程被注入了。多个不同进程 = 全局注入成功。
