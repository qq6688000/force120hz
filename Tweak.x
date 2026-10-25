// Force120Hz 1.2.0-min — 最小可用版本（用于故障定位）
//
// ============================================================================
// 这个版本只保留【一个】hook：
//
//     - [UIScreen maximumFramesPerSecond]  → 返回 120
//
// 为什么这么极端：
//   前面所有版本都在安全模式/崩溃循环里打转，我需要一个理论上不可能崩的版本
//   来确认一件事：崩溃到底是不是我的代码造成的。
//
//   这个 hook 的特征：
//     · 返回值是 NSInteger（整数），不是结构体，ABI 不会错
//     · 没有 block 参数，没有 CADisplayLink，没有 dispatch_after
//     · 不装信号处理器，不遍历类表，不做任何 I/O
//     · 连 marker 都不写（避免文件权限问题干扰判断）
//
//   如果这个版本还能让系统进安全模式 → 问题不在 hook 代码，指向：
//     a) 你的系统还停留在上次的安全模式里（需重启设备）
//     b) 其他插件冲突（ScreenRecord4K60 / SHELLX / SandyProxy ...）
//     c) ellekit 本身在加载这个 dylib 时有异常
//
//   如果这个版本正常 → 说明问题出在之前删掉的那些 hook 上（很可能是
//   CADisplayLink 的 setPreferredFrameRateRange:，它带结构体参数），
//   再逐个加回来定位。
// ============================================================================

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

%hook UIScreen
- (NSInteger)maximumFramesPerSecond {
    return 120;
}
%end
