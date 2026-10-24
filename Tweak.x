// Force120Hz 1.0.0 — global ProMotion 120Hz + app-launch animation speedup
//
// plist Filter.Mode = Any  → dylib loads into every process, so the frame-rate
// hooks are present wherever a render loop exists.  %ctor hard-gates non-UI
// processes on NSClassFromString(@"UIApplication") so daemons bail in ~0 cost.
//
// 120Hz  (all UI processes, incl. SpringBoard)
//   UIScreen.maximumFramesPerSecond  → 120
//   CADisplayLink +displayLinkWithTarget:selector: → preferredFrameRateRange 120/120/120
//   CADisplayLink setPreferredFrameRateRange:      → clamp incoming to 120/120/120
//   CADisplayLink setPreferredFramesPerSecond:     → clamp incoming to 120 (legacy API)
//   CAAnimation   setPreferredFrameRateRange:      → max/preferred 120 (min left low for idle)
//   + best-effort scene probe: UIWindowScene setPreferredFrameRateRange: /
//     _setPreferredFrameRateRange: (only called if the selector actually exists)
//
// Launch animation (SpringBoard only — those SB* classes exist nowhere else, so the
// probe is an automatic no-op in apps)
//   MSHookMessageEx per (class, selector) with its OWN captured orig IMP, installed
//   only when [cls instancesRespondToSelector:].  Own-orig-per-hook = no recursion when
//   a hooked subclass super-calls a hooked parent.  Selector absent on this iOS build =
//   skipped, never added as a spurious method.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <pthread.h>
#import <unistd.h>
#import <string.h>
#import <stdarg.h>
#import <dispatch/dispatch.h>

#define kVersion      @"1.0.0"
#define kPrefPath     @"/var/mobile/Library/Preferences/com.minis.force120hz.plist"
#define kMarkerPath   @"/var/mobile/Library/Preferences/com.minis.force120hz.loaded"
#define kLogPath      @"/var/mobile/Library/Preferences/com.minis.force120hz.log"
#define kStatusPath   @"/var/mobile/Library/Preferences/com.minis.force120hz.status"
#define kNfStatus     "com.minis.force120hz.status"
#define kNfReload     "com.minis.force120hz.reload"
#define kNfToggle120  "com.minis.force120hz.toggle120"
#define kNfToggleLch  "com.minis.force120hz.togglelaunch"

static BOOL   gForce120      = YES;
static BOOL   gLaunchSpeedup = YES;
static double gLaunchDivisor = 3.0;
static BOOL   gDebugLog      = YES;
static int    gLaunchHooks   = -1;   // -1 = not yet probed

#pragma mark - utils

static BOOL isSpringBoard(void) {
    const char *pn = getprogname();
    return pn && strcmp(pn, "SpringBoard") == 0;
}

static BOOL hasUIKit(void) {
    return NSClassFromString(@"UIApplication") && NSClassFromString(@"UIWindow");
}

static NSString *procName(void) {
    const char *pn = getprogname();
    return pn ? [NSString stringWithUTF8String:pn] : @"?";
}

static void DBLog(NSString *fmt, ...) {
    if (!gDebugLog) return;
    @try {
        va_list a; va_start(a, fmt);
        NSString *body = [[NSString alloc] initWithFormat:fmt arguments:a];
        va_end(a);
        NSString *ts = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                      dateStyle:NSDateFormatterShortStyle
                                                      timeStyle:NSDateFormatterMediumStyle];
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", ts, body];
        NSData *old = [NSData dataWithContentsOfFile:kLogPath];
        NSMutableData *md = old ? [old mutableCopy] : [NSMutableData data];
        if (md.length > 200 * 1024) {                    // ring-buffer cap
            NSUInteger keep = 12 * 1024;
            [md replaceBytesInRange:NSMakeRange(0, md.length - keep) withBytes:NULL length:0];
        }
        [md appendData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [md writeToFile:kLogPath atomically:YES];
    } @catch (id e) {}
}

static NSDictionary *loadPrefs(void) {
    @try {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPrefPath];
        return d ?: @{};
    } @catch (id e) { return @{}; }
}

static void refreshConfig(void) {
    NSDictionary *p = loadPrefs();
    if ([p objectForKey:@"Force120"])       gForce120      = [[p objectForKey:@"Force120"] boolValue];
    if ([p objectForKey:@"LaunchSpeedup"])  gLaunchSpeedup = [[p objectForKey:@"LaunchSpeedup"] boolValue];
    if ([p objectForKey:@"LaunchDivisor"])  gLaunchDivisor = [[p objectForKey:@"LaunchDivisor"] doubleValue];
    if (gLaunchDivisor < 1.0) gLaunchDivisor = 3.0;
    if ([p objectForKey:@"DebugLog"])       gDebugLog      = [[p objectForKey:@"DebugLog"] boolValue];
}

static void writeMarker(void) {
    @try {
        NSString *s = [NSString stringWithFormat:@"loaded %@ proc=%@ sb=%d pid=%d",
                       kVersion, procName(), isSpringBoard()?1:0, getpid()];
        [s writeToFile:kMarkerPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (id e) {}
}

#pragma mark - 120Hz helpers

static CAFrameRateRange maxRange(void) {
    return CAFrameRateRangeMake(120.0f, 120.0f, 120.0f);
}

static void applySceneFrameRate(UIWindowScene *scene) {
    if (!gForce120 || !scene) return;
    @try {
        if ([scene respondsToSelector:@selector(setPreferredFrameRateRange:)]) {
            ((void(*)(id,SEL,CAFrameRateRange))objc_msgSend)(scene,
                                                              @selector(setPreferredFrameRateRange:), maxRange());
        } else {
            SEL priv = sel_registerName("_setPreferredFrameRateRange:");
            if ([scene respondsToSelector:priv]) {
                ((void(*)(id,SEL,CAFrameRateRange))objc_msgSend)(scene, priv, maxRange());
            }
        }
    } @catch (id e) {}
}

static void applyAllScenes(void) {
    if (!gForce120) return;
    @try {
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes.allObjects) {
            if ([sc isKindOfClass:UIWindowScene.class]) applySceneFrameRate((UIWindowScene *)sc);
        }
    } @catch (id e) {}
}

#pragma mark - 120Hz hooks  (all UI processes)

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
            dl.preferredFrameRateRange = maxRange();
            if ([dl respondsToSelector:@selector(setPreferredFramesPerSecond:)])
                dl.preferredFramesPerSecond = 120;
        } @catch (id e) {}
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
    if (gForce120) { r.maximum = 120.0f; r.preferred = 120.0f; }
    %orig(r);
}
%end

// ---- launch animation speedup (generated per-hook orig IMPs) ----
#include "LaunchSpeedup.inc"

#pragma mark - status + CLI notifications

static NSString *statusString(void) {
    NSDictionary *p = loadPrefs();
    return [NSString stringWithFormat:
        @"Force120Hz %@ proc=%@ sb=%d pid=%d\n"
        @"  Force120      = %@   (plist %@)\n"
        @"  LaunchSpeedup = %@   divisor=%.1f  (plist %@)\n"
        @"  launch-hooks  = %d\n"
        @"  DebugLog      = %@\n"
        @"  marker        = %@",
        kVersion, procName(), isSpringBoard()?1:0, getpid(),
        gForce120?@"YES":@"NO", [p objectForKey:@"Force120"] ?: @"(default)",
        gLaunchSpeedup?@"YES":@"NO", gLaunchDivisor,
        [p objectForKey:@"LaunchSpeedup"] ?: @"(default)",
        gLaunchHooks,
        gDebugLog?@"YES":@"NO",
        ([[NSFileManager defaultManager] fileExistsAtPath:kMarkerPath]) ? @"present" : @"absent"];
}

static void postStatus(void) {
    @try {
        NSString *s = statusString();
        DBLog(@"status %@", s);
        [s writeToFile:kStatusPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
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
    DBLog(@"toggle120 -> %@", gForce120?@"ON":@"OFF");
    postStatus();
}

static void onToggleLaunch(int token) {
    gLaunchSpeedup = !gLaunchSpeedup;
    DBLog(@"toggleLaunch -> %@", gLaunchSpeedup?@"ON":@"OFF");
    postStatus();
}

#pragma mark - %ctor

%ctor {
    if (!hasUIKit()) return;              // every non-UI process bails here

    refreshConfig();
    BOOL sb = isSpringBoard();
    writeMarker();

    DBLog(@"=== Force120Hz %-6@ loaded in %@ (sb=%d pid=%d) Force120=%@ Launch=%@ divisor=%.1f ===",
          kVersion, procName(), sb?1:0, getpid(),
          gForce120?@"YES":@"NO", gLaunchSpeedup?@"YES":@"NO", gLaunchDivisor);

    // launch hooks: SpringBoard only, deferred so the class list is finalised
    if (sb) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            gLaunchHooks = installLaunchSpeedupHooks();
            DBLog(@"launch-speedup: %d duration hooks installed (divisor=%.1f)",
                  gLaunchHooks, gLaunchDivisor);
            postStatus();
        });
    }

    // scene frame-rate seeding (scenes not connected at %ctor time)
    if (gForce120) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ applyAllScenes(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ applyAllScenes(); });
    }

    @try {
        [NSNotificationCenter.defaultCenter addObserverForName:UISceneWillConnectNotification
                                                         object:nil queue:nil
                                                     usingBlock:^(NSNotification *n) {
            if ([n.object isKindOfClass:UIWindowScene.class])
                applySceneFrameRate((UIWindowScene *)n.object);
        }];
    } @catch (id e) {}

    notify_register_dispatch(kNfStatus,    NULL, dispatch_get_main_queue(), ^(int t){ onNotify(t); });
    notify_register_dispatch(kNfReload,    NULL, dispatch_get_main_queue(), ^(int t){ onNotify(t); });
    notify_register_dispatch(kNfToggle120, NULL, dispatch_get_main_queue(), ^(int t){ onToggle120(t); });
    notify_register_dispatch(kNfToggleLch, NULL, dispatch_get_main_queue(), ^(int t){ onToggleLaunch(t); });

    postStatus();
}
