// Force120Hz 1.0.1 — global ProMotion 120Hz + app-launch animation speedup
//
// Filter.Mode = Any  → dylib 注入每个进程，%ctor 用 hasUIKit() 挡住非 UI 进程。
//
// 1.0.1 相对 1.0.0 的改动（针对 iOS 16.5 / Dopamine rootless 上 marker 始终缺失）
//   1. 新增 __attribute__((constructor(100))) 的 f120_ctor_early：
//      优先级 100 < Logos 生成的默认优先级，所以它一定先于所有 hook 安装执行。
//      里面只做三件事：装诊断处理器 → 写 marker → 打 stage 日志。
//      marker 写入是纯 POSIX（open/write/fsync/close），不调 ObjC runtime、不读配置、
//      不建 CADisplayLink。只要 dylib 被注入成功，marker 就一定会落盘。
//      → marker 存在 = dylib 加载了；marker 缺失 = 注入环节失败，与插件代码无关。
//   2. NSSetUncaughtExceptionHandler + SIGSEGV/SIGBUS/SIGABRT/SIGILL 处理器，
//      崩溃时把 (信号号, 进程名, pid, 所处 stage) 追加写到 .crash，然后链回原 handler，
//      不吞崩溃、不掩盖 SpringBoard 自己的处理逻辑。
//   3. %ctor 主体全部包在 @try/@catch，任何一处异常都不会拖死宿主进程。
//   4. notify_register_dispatch 改用真实 token 变量（1.0.0 传 NULL）。
//   5. 配置解析全部做 isKindOfClass: 类型校验，挡住 [NSNull doubleValue] 这类
//      unimplemented selector 异常（1.0.0 里 refreshConfig 在 marker 之前就跑）。
//
// 120Hz  (所有 UI 进程，含 SpringBoard)
//   UIScreen.maximumFramesPerSecond                 → 120                (iOS 10.3+)
//   CADisplayLink +displayLinkWithTarget:selector: → range 120/120/120
//   CADisplayLink setPreferredFrameRateRange:       → 夹到 120/120/120    (iOS 15+)
//   CADisplayLink setPreferredFramesPerSecond:      → 夹到 120            (legacy)
//   CAAnimation   setPreferredFrameRateRange:       → max/preferred 120   (iOS 15+)
//   + best-effort 场景探测: UIWindowScene setPreferredFrameRateRange: /
//     _setPreferredFrameRateRange:（只在 selector 真实存在时调用）
//
// 启动动画加速（仅 SpringBoard —— 那些 SB* 类不存在于任何 App 进程，探测自动 no-op）
//   每个 (class, selector) 各持有一份独立捕获的 orig IMP，并且只在
//   [cls instancesRespondToSelector:] 为真时才装。独立 orig = hooked 子类 super call
//   到 hooked 父类时不会递归；selector 在这个 iOS 版本上不存在 = 直接跳过，
//   永远不会被硬加成一个幽灵方法。

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <objc/NSObjCRuntime.h>
#import <notify.h>
#import <pthread.h>
#import <unistd.h>
#import <string.h>
#import <stdarg.h>
#import <stdio.h>
#import <signal.h>
#import <fcntl.h>
#import <time.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <dispatch/dispatch.h>

#define kVersion "1.0.1"

// ---- C 层路径常量（marker/日志写入不依赖 ObjC，任何时刻可安全调用）----
static const char *kPrefPath   = "/var/mobile/Library/Preferences/com.minis.force120hz.plist";
static const char *kMarkerPath = "/var/mobile/Library/Preferences/com.minis.force120hz.loaded";
static const char *kLogPath    = "/var/mobile/Library/Preferences/com.minis.force120hz.log";
static const char *kStatusPath = "/var/mobile/Library/Preferences/com.minis.force120hz.status";
static const char *kCrashPath  = "/var/mobile/Library/Preferences/com.minis.force120hz.crash";

#define kNfStatus    "com.minis.force120hz.status"
#define kNfReload    "com.minis.force120hz.reload"
#define kNfToggle120 "com.minis.force120hz.toggle120"
#define kNfToggleLch "com.minis.force120hz.togglelaunch"

static BOOL   gForce120      = YES;
static BOOL   gLaunchSpeedup = YES;
static double gLaunchDivisor = 3.0;
static BOOL   gDebugLog      = YES;
static int    gLaunchHooks   = -1;     // -1 = 还没探测过
static int    gStage         = 0;      // 崩溃诊断：走到哪一步
static int    gMarkerOk      = 0;

#pragma mark - POSIX 层工具（纯 libc，不抛异常，信号安全子集见注释）

static const char *pn(void) { const char *p = getprogname(); return p ? p : "?"; }

static int isSB(void) { const char *p = getprogname(); return p && strcmp(p, "SpringBoard") == 0; }

// 进程里有没有 UIKit —— 用来挡 Filter.Mode=Any 注入进来的守护进程。
// NSClassFromString 不需要 UIKit 链接就能调，找不到就返回 nil。
static BOOL hasUIKit(void) {
    @try { return NSClassFromString(@"UIApplication") != nil; }
    @catch (id e) { return NO; }
}

// 追加一行到 .log。注意：本函数不是信号安全的（用了 strftime），只在正常路径调用。
static void rawLog(const char *fmt, ...) {
    if (!gDebugLog) return;
    char body[512];
    va_list a; va_start(a, fmt);
    vsnprintf(body, sizeof(body), fmt, a);
    va_end(a);

    time_t t = time(NULL);
    struct tm tmv;
    localtime_r(&t, &tmv);
    char ts[32];
    strftime(ts, sizeof(ts), "%m-%d %H:%M:%S", &tmv);

    char line[600];
    int n = snprintf(line, sizeof(line), "%s %s\n", ts, body);
    if (n <= 0) return;

    int fd = open(kLogPath, O_WRONLY | O_CREAT | O_APPEND, 0664);
    if (fd < 0) return;
    struct stat st;
    if (fstat(fd, &st) == 0 && st.st_size > 256 * 1024) {
        // 太大了，截断重来（简单粗暴，避免每次读改写）
        ftruncate(fd, 0);
        const char *hdr = "-- log truncated --\n";
        write(fd, hdr, strlen(hdr));
    }
    write(fd, line, n);
    close(fd);
}

// 崩溃诊断写入。这里只使用信号安全的调用（snprintf/open/write/close/getpid），
// 可以在信号处理函数里安全调用 —— 刻意不用 strftime/time。
static void dumpCrash(const char *what, int sig) {
    char buf[320];
    int n = snprintf(buf, sizeof(buf),
        "%s: sig=%d proc=%s pid=%d stage=%d marker=%d\n",
        what, sig, pn(), getpid(), gStage, gMarkerOk);
    if (n <= 0) return;
    int fd = open(kCrashPath, O_WRONLY | O_CREAT | O_APPEND, 0664);
    if (fd < 0) return;
    write(fd, buf, n);
    close(fd);
}

// marker —— 1.0.1 里这是 %ctor 序列中的第一件事，纯 POSIX，无 ObjC 依赖。
// 用 O_TRUNC：谁最后加载谁的内容留在文件里，一眼能看到最新版本号。
static void writeMarker(void) {
    char buf[256];
    int n = snprintf(buf, sizeof(buf),
        "loaded %s proc=%s sb=%d pid=%d\n", kVersion, pn(), isSB() ? 1 : 0, getpid());
    if (n <= 0) return;
    int fd = open(kMarkerPath, O_WRONLY | O_CREAT | O_TRUNC, 0664);
    if (fd < 0) return;
    write(fd, buf, (size_t)n);
    fsync(fd);
    close(fd);
    gMarkerOk = 1;
}

#pragma mark - 崩溃诊断处理器

static struct sigaction s_prevSegv, s_prevBus, s_prevAb, s_prevIll;
static NSUncaughtExceptionHandler *s_prevEx = NULL;

static void sigDump(int sig, siginfo_t *si, void *ctx) {
    (void)si; (void)ctx;
    dumpCrash("SIGNAL", sig);
    struct sigaction *prev = NULL;
    switch (sig) {
        case SIGSEGV: prev = &s_prevSegv; break;
        case SIGBUS:  prev = &s_prevBus;  break;
        case SIGABRT: prev = &s_prevAb;   break;
        case SIGILL:  prev = &s_prevIll;  break;
    }
    if (prev) {
        void *ph = (void *)prev->sa_sigaction;
        if (ph != (void *)SIG_DFL && ph != (void *)SIG_IGN && ph != (void *)sigDump) {
            // 链回宿主进程自己的 handler，不掩盖原有行为
            // 注意：sa_handler 与 sa_sigaction 是 union，但签名不同 —— 必须经 sa_sigaction 调用
            prev->sa_sigaction(sig, si, ctx);
            return;
        }
    }
    struct sigaction d;
    memset(&d, 0, sizeof(d));
    sigemptyset(&d.sa_mask);
    d.sa_handler = SIG_DFL;
    sigaction(sig, &d, NULL);
    raise(sig);
}

static void exDump(NSException *ex) {
    dumpCrash("NSException", 0);
    @try {
        const char *nm = ex.name ? [ex.name UTF8String] : NULL;
        const char *rs = ex.reason ? [ex.reason UTF8String] : NULL;
        rawLog("UNCAUGHT NSException stage=%d name=%s reason=%s",
               gStage, nm ? nm : "?", rs ? rs : "?");
    } @catch (id e) {}
    if (s_prevEx) s_prevEx(ex);
}

static void installDiagHandlers(void) {
    struct sigaction a;
    memset(&a, 0, sizeof(a));
    a.sa_sigaction = sigDump;
    sigemptyset(&a.sa_mask);
    a.sa_flags = SA_SIGINFO;
    sigaction(SIGSEGV, &a, &s_prevSegv);
    sigaction(SIGBUS,  &a, &s_prevBus);
    sigaction(SIGABRT, &a, &s_prevAb);
    sigaction(SIGILL,  &a, &s_prevIll);

    s_prevEx = NSGetUncaughtExceptionHandler();
    NSSetUncaughtExceptionHandler(exDump);
}

#pragma mark - 配置读取（全程类型校验，绝不把 NSNull 当 NSNumber 用）

static NSDictionary *loadPrefs(void) {
    @try {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:
                          [NSString stringWithUTF8String:kPrefPath]];
        return d ?: @{};
    } @catch (id e) {
        rawLog("loadPrefs threw: %s", e ? [[e name] UTF8String] : "?");
        return @{};
    }
}

static BOOL bVal(NSDictionary *d, NSString *k, BOOL dflt) {
    @try {
        id v = [d objectForKey:k];
        return [v isKindOfClass:NSNumber.class] ? [v boolValue] : dflt;
    } @catch (id e) { return dflt; }
}

static double dVal(NSDictionary *d, NSString *k, double dflt) {
    @try {
        id v = [d objectForKey:k];
        return [v isKindOfClass:NSNumber.class] ? [v doubleValue] : dflt;
    } @catch (id e) { return dflt; }
}

static void refreshConfig(void) {
    @try {
        NSDictionary *p = loadPrefs();
        gForce120      = bVal(p, @"Force120",      gForce120);
        gLaunchSpeedup = bVal(p, @"LaunchSpeedup", gLaunchSpeedup);
        gLaunchDivisor = dVal(p, @"LaunchDivisor", gLaunchDivisor);
        if (gLaunchDivisor < 1.0)  gLaunchDivisor = 1.0;    // 1.0 = 不加速
        if (gLaunchDivisor > 60.0) gLaunchDivisor = 60.0;   // 防呆：再大也没意义还会崩时序
        gDebugLog      = bVal(p, @"DebugLog",      gDebugLog);
    } @catch (id e) {
        rawLog("refreshConfig threw: %s", e ? [[e name] UTF8String] : "?");
    }
}

#pragma mark - 120Hz 辅助

static CAFrameRateRange maxRange(void) {
    return CAFrameRateRangeMake(120.0f, 120.0f, 120.0f);
}

// 场景级探测：UIKit 里 UIWindowScene 并没有公开这个 selector，16.5 SDK 确认不存在。
// 所以这几乎总是 no-op；保留是为万一某个 iOS 版本真的有它。只在真实存在时调用。
static void applySceneFrameRate(UIWindowScene *scene) {
    if (!gForce120 || !scene) return;
    @try {
        if ([scene respondsToSelector:@selector(setPreferredFrameRateRange:)]) {
            ((void(*)(id,SEL,CAFrameRateRange))objc_msgSend)(scene,
                                                              @selector(setPreferredFrameRateRange:),
                                                              maxRange());
            rawLog("scene: setPreferredFrameRateRange 120 ok");
        } else {
            SEL priv = sel_registerName("_setPreferredFrameRateRange:");
            if ([scene respondsToSelector:priv]) {
                ((void(*)(id,SEL,CAFrameRateRange))objc_msgSend)(scene, priv, maxRange());
                rawLog("scene: _setPreferredFrameRateRange 120 ok");
            }
        }
    } @catch (id e) {
        rawLog("applySceneFrameRate threw: %s", e ? [[e name] UTF8String] : "?");
    }
}

static void applyAllScenes(void) {
    if (!gForce120) return;
    @try {
        NSArray *scenes = [UIApplication sharedApplication].connectedScenes.allObjects;
        NSUInteger hit = 0;
        for (UIScene *sc in scenes) {
            if ([sc isKindOfClass:UIWindowScene.class]) {
                applySceneFrameRate((UIWindowScene *)sc);
                hit++;
            }
        }
        rawLog("applyAllScenes: %lu scene(s) touched", (unsigned long)hit);
    } @catch (id e) {
        rawLog("applyAllScenes threw: %s", e ? [[e name] UTF8String] : "?");
    }
}

#pragma mark - 120Hz hooks（所有 UI 进程）

%hook UIScreen
- (NSInteger)maximumFramesPerSecond {
    NSInteger v = %orig;
    if (gForce120 && v < 120) return 120;
    return v;
}
%end

%hook CADisplayLink
+ (instancetype)displayLinkWithTarget:(id)target selector:(SEL)sel {
    CADisplayLink *dl = %orig;
    if (gForce120 && dl) {
        @try {
            dl.preferredFrameRateRange = maxRange();      // iOS 15+
            if ([dl respondsToSelector:@selector(setPreferredFramesPerSecond:)])
                dl.preferredFramesPerSecond = 120;         // legacy API
        } @catch (id e) {
            rawLog("CADisplayLink set range threw: %s", e ? [[e name] UTF8String] : "?");
        }
    }
    return dl;
}
- (void)setPreferredFrameRateRange:(CAFrameRateRange)r {
    if (gForce120) { r.minimum = 120.0f; r.maximum = 120.0f; r.preferred = 120.0f; }
    %orig(r);
}
- (void)setPreferredFramesPerSecond:(NSInteger)fps {
    if (gForce120 && fps < 120) fps = 120;
    %orig(fps);
}
%end

%hook CAAnimation
- (void)setPreferredFrameRateRange:(CAFrameRateRange)r {
    if (gForce120) { r.maximum = 120.0f; r.preferred = 120.0f; }   // min 保持低值，空闲仍可降帧省电
    %orig(r);
}
%end

// ---- 启动动画加速（每个 hook 各持独立 orig，见 gen_launch.py）----
#include "LaunchSpeedup.inc"

#pragma mark - status + CLI 通知

static NSString *statusString(void) {
    @try {
        NSDictionary *p = loadPrefs();
        NSString *mk = [NSString stringWithUTF8String:kMarkerPath];
        return [NSString stringWithFormat:
            @"Force120Hz %-6s proc=%s sb=%d pid=%d\n"
            @"  Force120      = %-3s   (plist %@)\n"
            @"  LaunchSpeedup = %-3s   divisor=%.1f  (plist %@)\n"
            @"  launch-hooks  = %d\n"
            @"  DebugLog      = %-3s\n"
            @"  marker        = %s\n"
            @"  stage         = %d",
            kVersion, pn(), isSB() ? 1 : 0, getpid(),
            gForce120 ? "YES" : "NO", [p objectForKey:@"Force120"] ?: @"(default)",
            gLaunchSpeedup ? "YES" : "NO", gLaunchDivisor,
            [p objectForKey:@"LaunchSpeedup"] ?: @"(default)",
            gLaunchHooks,
            gDebugLog ? "YES" : "NO",
            [[NSFileManager defaultManager] fileExistsAtPath:mk] ? "present" : "absent",
            gStage];
    } @catch (id e) { return [NSString stringWithFormat:@"Force120Hz %-6s status threw", kVersion]; }
}

static void postStatus(void) {
    @try {
        NSString *s = statusString();
        rawLog("status: %s", [s UTF8String]);
        NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
        if (d) [d writeToFile:[NSString stringWithUTF8String:kStatusPath] atomically:YES];
        notify_post(kNfStatus);
    } @catch (id e) {}
}

static void onNotify(int token) {
    (void)token;
    refreshConfig();
    applyAllScenes();
    postStatus();
}

static void onToggle120(int token) {
    (void)token;
    gForce120 = !gForce120;
    rawLog("toggle120 -> %s", gForce120 ? "ON" : "OFF");
    postStatus();
}

static void onToggleLaunch(int token) {
    (void)token;
    gLaunchSpeedup = !gLaunchSpeedup;
    rawLog("toggleLaunch -> %s", gLaunchSpeedup ? "ON" : "OFF");
    postStatus();
}

#pragma mark - 早期构造函数

// 关键：__attribute__((constructor(100))) 的优先级 100 远小于 Logos 为 %hook 生成的
// 默认优先级构造函数，所以本函数一定先于任何 MSHookMessageEx 调用执行。
// 因此即使某个 hook 安装出了问题，marker 也已经被写下来了 —— 我们能分清
// 「dylib 被注入了」和「hook 装坏了」这两种完全不同的故障。
__attribute__((constructor(100)))
static void f120_ctor_early(void) {
    installDiagHandlers();
    gStage = 1;
    if (!hasUIKit()) return;          // 非 UI 进程（守护进程等）到此为止，零开销
    writeMarker();
    gStage = 2;
    rawLog("=== Force120Hz %s ctor-early proc=%s sb=%d pid=%d ===",
           kVersion, pn(), isSB() ? 1 : 0, getpid());
}

#pragma mark - %ctor（主体）

%ctor {
    @try {
        refreshConfig();
        gStage = 3;
        BOOL sb = isSB();

        rawLog("=== Force120Hz %s loaded in %s (sb=%d pid=%d) Force120=%s Launch=%s divisor=%.1f ===",
               kVersion, pn(), sb ? 1 : 0, getpid(),
               gForce120 ? "YES" : "NO", gLaunchSpeedup ? "YES" : "NO", gLaunchDivisor);

        // 启动动画加速：仅 SpringBoard。延迟到主线程，让运行时类表先定稿。
        if (sb) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @try {
                    gLaunchHooks = installLaunchSpeedupHooks();
                    rawLog("launch-speedup: %d duration hook(s) installed (divisor=%.1f)",
                           gLaunchHooks, gLaunchDivisor);
                    gStage = 5;
                    postStatus();
                } @catch (id e) {
                    rawLog("installLaunchSpeedupHooks threw: %s", e ? [[e name] UTF8String] : "?");
                }
            });
        } else {
            gLaunchHooks = 0;
        }

        gStage = 4;
        // 场景帧率播种（%ctor 时 scene 往往还没连接）
        if (gForce120) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ @try { applyAllScenes(); } @catch (id e) {} });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ @try { applyAllScenes(); } @catch (id e) {} });
        }

        [NSNotificationCenter.defaultCenter addObserverForName:UISceneWillConnectNotification
                                                         object:nil queue:nil
                                                     usingBlock:^(NSNotification *n) {
            @try {
                if ([n.object isKindOfClass:UIWindowScene.class])
                    applySceneFrameRate((UIWindowScene *)n.object);
            } @catch (id e) {}
        }];

        // notify tokens 必须是真实变量（1.0.0 传 NULL）
        static int s_tok[4] = {0, 0, 0, 0};
        notify_register_dispatch(kNfStatus,    &s_tok[0], dispatch_get_main_queue(), ^(int t){ onNotify(t); });
        notify_register_dispatch(kNfReload,    &s_tok[1], dispatch_get_main_queue(), ^(int t){ onNotify(t); });
        notify_register_dispatch(kNfToggle120, &s_tok[2], dispatch_get_main_queue(), ^(int t){ onToggle120(t); });
        notify_register_dispatch(kNfToggleLch, &s_tok[3], dispatch_get_main_queue(), ^(int t){ onToggleLaunch(t); });

        gStage = 6;
        postStatus();
    } @catch (id e) {
        rawLog("MAIN CTOR THREW stage=%d name=%s reason=%s",
               gStage, e ? [[e name] UTF8String] : "?", e ? [[e reason] UTF8String] : "?");
        gStage = -1;
        writeMarker();   // 即便崩了也把版本和进程留下
    }
}
