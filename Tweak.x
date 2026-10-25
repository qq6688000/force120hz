// Force120Hz 1.3.0 — 全局 120Hz + 启动动画加速
//
// ============================================================================
// 1.3.0 —— 120Hz + 启动动画加速（CAAnimation setDuration 方案）
//
// 前三次尝试的实测结论（不要再走弯路）：
//
//   1) hook SB 私有类的 duration 方法
//      探测扫了 90071 个已注册类，SBApp* / SBApplication* 下 0 个带 duration。
//      类名属于旧 iOS，17.3.1 上不存在。
//
//   2) hook UIView 类方法 +animateWithDuration:animations:
//      1.0.7~1.0.9 传类对象 → 被当成实例方法 → 挂在不存在的实例方法上 → no-op
//      （所以显示 launch-hooks=4 却不崩，是假成功）。
//      1.1.0 用 object_getClass 拿到元类正确挂载 → SpringBoard 每 10 秒崩溃重启。
//      原因：UIView 动画类方法是 SpringBoard 每个动画的入口，无法限定作用域。
//      → 永久放弃。
//
//   3) 【本版】hook -[CAAnimation setDuration:]（CAMediaTiming.h:43）
//      · 类型 CFTimeInterval = double，单个标量参数，ABI 最简单
//      · 只改「这个动画播多久」，不改变调度入口，影响面远小于方案 2
//      · 是【实例方法】，所以挂载目标是类对象本身
//      · isSB() 守卫，不影响任何 App 自己的动画
//
// 120Hz 部分（1.0.7 起的稳定实现，实测 458 进程注入、零崩溃）：
//   -[UIScreen maximumFramesPerSecond]            → 120
//   +[CADisplayLink displayLinkWithTarget:selector:] → 设 120/120/120
//   -[CADisplayLink setPreferredFrameRateRange:]  → 夹到 120/120/120
//   录屏/投屏时（UIScreen.isCaptured）完全跳过帧率干预
// ============================================================================

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <unistd.h>
#import <string.h>
#import <stdarg.h>
#import <stdio.h>
#import <fcntl.h>
#import <time.h>
#import <sys/stat.h>

#define kVersion "1.3.0"

static const char *kPrefPath   = "/var/mobile/Library/Preferences/com.minis.force120hz.plist";
static const char *kMarkerPath = "/var/mobile/Library/Preferences/com.minis.force120hz.loaded";
static const char *kLogPath    = "/var/mobile/Library/Preferences/com.minis.force120hz.log";
static const char *kStatusPath = "/var/mobile/Library/Preferences/com.minis.force120hz.status";
// SpringBoard 单独一份：启动加速只在 SB 里生效，混写同一个文件会被
// 后启动的 App 进程覆盖，导致永远看不到真实的 launch-hooks 数。
static const char *kSBStatusPath = "/var/mobile/Library/Preferences/com.minis.force120hz.sbstatus";
static const char *kSafePath   = "/var/mobile/Library/Preferences/com.minis.force120hz.safemode";

#define kNfStatus    "com.minis.force120hz.status"
#define kNfReload    "com.minis.force120hz.reload"

static BOOL   gForce120      = YES;
static BOOL   gLaunchSpeedup = YES;   // 默认开启
static double gLaunchDivisor = 5.0;   // 默认 5 倍
static BOOL   gDebugLog      = YES;
static BOOL   gSafeMode      = NO;
static int    gLaunchHooks   = -1;

#pragma mark - 纯 POSIX 工具（不碰 ObjC runtime，任何时刻可安全调用）

static const char *pn(void) { const char *p = getprogname(); return p ? p : "?"; }
static int isSB(void) { const char *p = getprogname(); return p && strcmp(p, "SpringBoard") == 0; }

static int fileExists(const char *p) {
    struct stat st;
    return (stat(p, &st) == 0);
}

static void rawLog(const char *fmt, ...) {
    if (!gDebugLog) return;
    char body[400];
    va_list a; va_start(a, fmt);
    vsnprintf(body, sizeof(body), fmt, a);
    va_end(a);
    time_t t = time(NULL);
    struct tm tmv; localtime_r(&t, &tmv);
    char ts[24]; strftime(ts, sizeof(ts), "%m-%d %H:%M:%S", &tmv);
    char line[448];
    int n = snprintf(line, sizeof(line), "%s %s\n", ts, body);
    if (n <= 0) return;
    int fd = open(kLogPath, O_WRONLY | O_CREAT | O_APPEND, 0664);
    if (fd < 0) return;
    struct stat st;
    if (fstat(fd, &st) == 0 && st.st_size > 192 * 1024) ftruncate(fd, 0);
    write(fd, line, (size_t)n);
    close(fd);
}

// marker：constructor 里的第一个动作，无条件、纯 POSIX。
// 只要 dylib 被注入成功就一定落盘 —— 这是「注入是否发生」的唯一权威判据。
// marker 用【追加】写，不是覆盖。每个被注入的进程都留一行，
// 这样才能看出「哪些进程真的被注入了」——覆盖写会让最后一个进程
// 把前面全部冲掉，误判为"只有终端被注入"。
// 文件超过 32KB 时清空重来，避免无限增长（每个 App 打开都追加一次）。
static void writeMarker(const char *tag) {
    char buf[224];
    int n = snprintf(buf, sizeof(buf),
        "%ld %s proc=%s sb=%d pid=%d safe=%d note=%s\n",
        (long)time(NULL), kVersion, pn(), isSB() ? 1 : 0, getpid(),
        gSafeMode ? 1 : 0, tag ? tag : "-");
    if (n <= 0) return;

    struct stat st;
    if (stat(kMarkerPath, &st) == 0 && st.st_size > 32 * 1024) unlink(kMarkerPath);

    int fd = open(kMarkerPath, O_WRONLY | O_CREAT | O_APPEND, 0664);
    if (fd < 0) return;
    write(fd, buf, (size_t)n);
    close(fd);
}

#pragma mark - 配置（类型严格校验，绝不把 NSNull 当 NSNumber）

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
        NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:
                           [NSString stringWithUTF8String:kPrefPath]];
        if (!p) return;
        gForce120      = bVal(p, @"Force120",      gForce120);
        gLaunchSpeedup = bVal(p, @"LaunchSpeedup", gLaunchSpeedup);
        gLaunchDivisor = dVal(p, @"LaunchDivisor", gLaunchDivisor);
        if (gLaunchDivisor < 1.0)  gLaunchDivisor = 1.0;
        if (gLaunchDivisor > 30.0) gLaunchDivisor = 30.0;
        gDebugLog      = bVal(p, @"DebugLog",      gDebugLog);
    } @catch (id e) {
        rawLog("refreshConfig threw");
    }
}

#pragma mark - 120Hz：只 hook 公开 API

// UIScreen.h:87  @property (readonly) NSInteger maximumFramesPerSecond
%hook UIScreen
- (NSInteger)maximumFramesPerSecond {
    NSInteger v = %orig;
    if (gForce120 && !gSafeMode && v < 120) return 120;
    return v;
}
%end

// CADisplayLink.h — 这三个在 SDK header 里都有明确声明，签名确定。
%hook CADisplayLink
+ (instancetype)displayLinkWithTarget:(id)target selector:(SEL)sel {
    CADisplayLink *dl = %orig;
    if (gForce120 && !gSafeMode && dl) {
        @try {
            // iOS 15+ 才有 preferredFrameRateRange，先确认再设
            if ([dl respondsToSelector:@selector(setPreferredFrameRateRange:)])
                dl.preferredFrameRateRange = CAFrameRateRangeMake(120.0f, 120.0f, 120.0f);
        } @catch (id e) { rawLog("displayLink set range threw"); }
    }
    return dl;
}

- (void)setPreferredFrameRateRange:(CAFrameRateRange)r {
    if (gForce120 && !gSafeMode) {
        r.minimum = 120.0f; r.maximum = 120.0f; r.preferred = 120.0f;
    }
    %orig(r);
}
%end

// 启动动画加速（默认关闭，见文件头说明；只含无参、返回 double 的候选）
#include "LaunchSpeedup.inc"


#pragma mark - 类名探测（只在 SpringBoard 里跑，结果写进日志）

// 候选表命中不了时，用这个直接问运行时「到底有哪些类」。
// objc_getClassList 能拿到全部已注册类，按前缀过滤即可。
// 结果同时写进日志和 sbstatus，不用再猜。

static void probeClasses(const char *prefix, const char *label) {
    @try {
        int total = objc_getClassList(NULL, 0);
        if (total <= 0) { rawLog("probe %s: class list empty", label); return; }

        Class *list = (Class *)malloc(sizeof(Class) * (size_t)total);
        if (!list) return;
        total = objc_getClassList(list, total);

        size_t plen = strlen(prefix);
        int hits = 0;
        rawLog("probe %s: scanning %d classes for prefix '%s'", label, total, prefix);
        for (int i = 0; i < total; i++) {
            const char *cn = class_getName(list[i]);
            if (!cn || strncmp(cn, prefix, plen) != 0) continue;
            // 只要我们自己关心的那几个方法，别把整个类表刷进日志
            BOOL hasDur = class_getInstanceMethod(list[i], sel_registerName("duration")) != NULL;
            BOOL hasComp = class_getInstanceMethod(list[i], sel_registerName("completionDuration")) != NULL;
            BOOL hasAnim = class_getInstanceMethod(list[i], sel_registerName("animationDuration")) != NULL;
            if (hasDur || hasComp || hasAnim) {
                rawLog("  HIT %s  duration=%d completionDuration=%d animationDuration=%d",
                       cn, hasDur, hasComp, hasAnim);
                hits++;
            }
        }
        free(list);
        rawLog("probe %s: %d candidate class(es) with duration-ish selectors", label, hits);
    } @catch (id e) {
        rawLog("probe %s threw", label);
    }
}

static void runProbes(void) {
    probeClasses("SBApp", "SBApp*");
    probeClasses("SBApplication", "SBApplication*");
}




#pragma mark - status

static NSString *statusString(void) {
    @try {
        return [NSString stringWithFormat:
            @"Force120Hz %-6s proc=%s sb=%d pid=%d\n"
            @"  Force120      = %-3s\n"
            @"  LaunchSpeedup = %-3s  divisor=%.1f\n"
            @"  SafeMode      = %-3s%s\n"
            @"  launch-hooks  = %d",
            kVersion, pn(), isSB() ? 1 : 0, getpid(),
            gForce120 ? "YES" : "NO",
            gLaunchSpeedup ? "YES" : "NO", gLaunchDivisor,
            gSafeMode ? "YES" : "NO",
            gSafeMode ? "  (marker-only, no hooks)" : "",
            gLaunchHooks];
    } @catch (id e) { return @"status threw"; }
}

static void postStatus(void) {
    @try {
        NSString *s = statusString();
        rawLog("status: %s", [s UTF8String]);
        NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
        if (!d) return;
        [d writeToFile:[NSString stringWithUTF8String:kStatusPath] atomically:YES];
        // SpringBoard 额外写一份专属文件。App 进程只写上面那份，
        // 不会覆盖这里 —— 否则 f120 status 看到的永远是终端/最后一个 App 的数字。
        if (isSB()) [d writeToFile:[NSString stringWithUTF8String:kSBStatusPath] atomically:YES];
        notify_post(kNfStatus);
    } @catch (id e) {}
}

static void onReload(int token) {
    (void)token;
    refreshConfig();
    postStatus();
}

#pragma mark - 早期构造函数

// constructor(100) 优先级低于 Logos 生成的 hook 安装 ctor，所以本函数先跑。
// 第一件事就是写 marker —— 任何检查都不能排在它前面（1.0.1 在这里踩过坑：
// SpringBoard 里 NSClassFromString(@"UIApplication") 可能返回 nil，
// 把检查放在 marker 之前等于废掉了唯一的诊断判据）。
__attribute__((constructor(100)))
static void f120_early(void) {
    gSafeMode = fileExists(kSafePath);
    writeMarker("ctor-early");
    if (!gSafeMode) {
        refreshConfig();
        rawLog("=== Force120Hz %s early proc=%s sb=%d pid=%d Force120=%s Launch=%s ===",
               kVersion, pn(), isSB() ? 1 : 0, getpid(),
               gForce120 ? "YES" : "NO", gLaunchSpeedup ? "YES" : "NO");
    }
}

#pragma mark - %ctor

%ctor {
    @try {
        if (gSafeMode) {
            rawLog("SAFEMODE: marker only, no hooks installed");
            postStatus();
            return;
        }

        // 启动加速：只在 SpringBoard，延迟 3 秒让运行时类表定稿。
        // 默认 gLaunchSpeedup=NO，此时 installLaunchSpeedupHooksImpl() 直接返回 0。
        if (isSB()) {
            if (gLaunchSpeedup) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    @try {
                        gLaunchHooks = installLaunchSpeedupHooksImpl();
                        rawLog("launch-speedup: %d hook(s), divisor=%.1f", gLaunchHooks, gLaunchDivisor);
                        postStatus();
                    } @catch (id e) { rawLog("installLaunchSpeedupHooksImpl threw"); }
                });
            } else {
                gLaunchHooks = 0;
                rawLog("launch-speedup: 已关闭（f120 launch on 开启）");
            }
        } else {
            gLaunchHooks = 0;
        }

        static int tok = 0;
        notify_register_dispatch(kNfReload, &tok, dispatch_get_main_queue(), ^(int t){ onReload(t); });

        postStatus();
    } @catch (id e) {
        rawLog("CTOR THREW");
        writeMarker("ctor-threw");
    }
}
