#import "CuriumPictureInPictureHooks.h"
#import "CuriumHookSupport.h"
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <os/log.h>

// Runtime hooks on the engine's CuriumPiPBridge, the Objective-C object that owns
// the AVPictureInPictureController for a video. Each hook is listed in
// .agents/TODO.md with the engine change that retires it.

static os_log_t CuriumPiPLog(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.appautomaton.curium", "engine");
    });
    return log;
}

#pragma mark - Close crash

// Engines up to build 35 ship a bridge whose -dealloc calls
// -teardownObserversAndViews, which queues a render-queue block capturing self.
// After Picture in Picture closes, the bridge's last reference is dropped on that
// render queue, so the block retains an object already being deallocated and later
// releases freed memory: EXC_BAD_ACCESS in objc_release on com.curium.ios.pip.renderer.
//
// The owner tears the bridge down on the UI sequence before releasing it, so dealloc
// only needs to repeat the observer cleanup, without blocks that capture self. This
// mirrors the engine fix in commit fb14c22; engines carrying it define
// -detachObservers and are left alone.

typedef void (*CuriumDeallocIMP)(__unsafe_unretained id, SEL);

static CuriumDeallocIMP gCuriumPiPBridgeSuperDealloc;
static Ivar gCuriumPiPObservers[4];
static Ivar gCuriumPiPDeallocController;
static Ivar gCuriumPiPObservingPossible;
static Ivar gCuriumPiPHostView;

// self is unretained: retaining an object inside its own dealloc is what crashed.
static void CuriumPiPBridgeDealloc(__unsafe_unretained id self, SEL _cmd) {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (size_t i = 0; i < 4; i++) {
        id observer = object_getIvar(self, gCuriumPiPObservers[i]);
        if (observer) {
            [center removeObserver:observer];
        }
    }
    bool *observingPossible = CuriumIvarAddress(self, gCuriumPiPObservingPossible);
    id controller = object_getIvar(self, gCuriumPiPDeallocController);
    if (*observingPossible && controller) {
        [controller removeObserver:self forKeyPath:@"pictureInPicturePossible"];
        *observingPossible = false;
    }
    // dealloc may run on the render queue; UIKit work hops to main without self.
    UIView *hostView = object_getIvar(self, gCuriumPiPHostView);
    if (hostView) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [hostView removeFromSuperview];
        });
    }
    gCuriumPiPBridgeSuperDealloc(self, _cmd);
}

static void CuriumInstallPiPCloseFix(Class cls) {
    if (class_getInstanceMethod(cls, sel_registerName("detachObservers"))) {
        os_log(CuriumPiPLog(), "pip close fix: not needed, engine has detachObservers");
        CuriumRecordHookStatus(@"PiP Dealloc Fix", @"skipped",
                               @"Engine provides native detachObservers");
        return;
    }
    const char *observerNames[4] = {"_didEnterBgObserver", "_willEnterFgObserver",
                                    "_failedToDecodeObserver", "_requiresFlushObserver"};
    BOOL layoutMatches = YES;
    for (size_t i = 0; i < 4; i++) {
        gCuriumPiPObservers[i] = CuriumExpectIvar(cls, observerNames[i], "@");
        layoutMatches = layoutMatches && gCuriumPiPObservers[i];
    }
    gCuriumPiPDeallocController =
        CuriumExpectIvar(cls, "_pipController", "@\"AVPictureInPictureController\"");
    gCuriumPiPObservingPossible = CuriumExpectIvar(cls, "_observingPossible", "B");
    gCuriumPiPHostView = CuriumExpectIvar(cls, "_hostView", "@\"CuriumPiPHostView\"");
    SEL dealloc = sel_registerName("dealloc");
    Method method = class_getInstanceMethod(cls, dealloc);
    IMP superDealloc = class_getMethodImplementation(class_getSuperclass(cls), dealloc);
    // Fail closed: on an unexpected layout, keep the engine's own dealloc.
    if (!layoutMatches || !gCuriumPiPDeallocController || !gCuriumPiPObservingPossible ||
        !gCuriumPiPHostView || !method || method_getImplementation(method) == superDealloc) {
        os_log_error(CuriumPiPLog(), "pip close fix: skipped, unexpected CuriumPiPBridge layout");
        CuriumRecordHookStatus(@"PiP Dealloc Fix", @"failed",
                               @"Unexpected CuriumPiPBridge dealloc layout");
        return;
    }
    gCuriumPiPBridgeSuperDealloc = (CuriumDeallocIMP)superDealloc;
    method_setImplementation(method, (IMP)CuriumPiPBridgeDealloc);
    os_log(CuriumPiPLog(), "pip close fix: installed");
    CuriumRecordHookStatus(@"PiP Dealloc Fix", @"active",
                           @"Replaced dealloc without render-queue self-retain");
}

#pragma mark - Start when ready

// Every session builds a fresh AVPictureInPictureController in
// -prepareHostInWindow:naturalSize:generation: and the engine starts it about 5 ms
// later, before the controller is ready. ac_duo logs (2026-11-20) show two failures:
// - Pegasus has not confirmed the controller yet (isSystemPictureInPicturePossible
//   is NO although pictureInPicturePossible already reads YES), so AVKit logs
//   "startPictureInPicture failed; status = 0" and never calls the delegate;
// - the display layer has no frame yet (contentDimensions 0 x 0), so Pegasus fails
//   the start with PGPegasusErrorDomain -1003 and AVKit calls the delegate twice.
// A second tap reused the warm controller and succeeded every time.
//
// This hook holds the engine's start until the controller has settled and its layer
// is rendering, and retries a delegate-reported failure once on the same controller
// before the engine hears of it. The engine's own 6 s start timeout stays the
// backstop. Worst case before the engine learns the outcome: about 2.2 s, inside
// CuriumPictureInPictureState.confirmationTimeout.

static const CFTimeInterval kCuriumPiPSettleSeconds = 0.15;
static const CFTimeInterval kCuriumPiPReadyDeadlineSeconds = 0.6;
static const CFTimeInterval kCuriumPiPPollSeconds = 0.03;
static const CFTimeInterval kCuriumPiPRetryDelaySeconds = 0.25;
static const NSUInteger kCuriumPiPMaxRetries = 1;

typedef void (*CuriumPiPStartIMP)(id, SEL, uint64_t);
typedef void (*CuriumPiPFailedIMP)(id, SEL, AVPictureInPictureController *, NSError *);

static CuriumPiPStartIMP gCuriumPiPEngineStart;
static CuriumPiPFailedIMP gCuriumPiPEngineFailed;
static Ivar gCuriumPiPController;
static Ivar gCuriumPiPDisplayLayer;
static Ivar gCuriumPiPActiveGeneration;
static Ivar gCuriumPiPAttemptGeneration;
static Ivar gCuriumPiPAttemptActive;
static Ivar gCuriumPiPActive;

static char kCuriumPiPFirstSeenKey;
static char kCuriumPiPRetryKey;

// Retry bookkeeping for one bridge, reset whenever the generation changes.
@interface CuriumPiPRetryState : NSObject
@property(nonatomic) uint64_t generation;
@property(nonatomic) NSUInteger count;
// A retry is scheduled; failures delivered meanwhile are duplicates of the last one.
@property(nonatomic) BOOL pending;
@end

@implementation CuriumPiPRetryState
@end

static CuriumPiPRetryState *CuriumPiPRetryStateFor(id bridge, uint64_t generation) {
    CuriumPiPRetryState *state = objc_getAssociatedObject(bridge, &kCuriumPiPRetryKey);
    if (!state || state.generation != generation) {
        state = [CuriumPiPRetryState new];
        state.generation = generation;
        objc_setAssociatedObject(bridge, &kCuriumPiPRetryKey, state,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

static uint64_t CuriumPiPActiveGeneration(id bridge) {
    return *(uint64_t *)CuriumIvarAddress(bridge, gCuriumPiPActiveGeneration);
}

// True while the engine is waiting on this generation's start: the same
// controller, an open attempt for the active generation, and no live window.
static BOOL CuriumPiPAttemptOpen(id bridge, AVPictureInPictureController *controller,
                                 uint64_t generation) {
    return object_getIvar(bridge, gCuriumPiPController) == controller &&
           CuriumPiPActiveGeneration(bridge) == generation &&
           *(uint64_t *)CuriumIvarAddress(bridge, gCuriumPiPAttemptGeneration) == generation &&
           *(bool *)CuriumIvarAddress(bridge, gCuriumPiPAttemptActive) &&
           !*(bool *)CuriumIvarAddress(bridge, gCuriumPiPActive) &&
           !controller.isPictureInPictureActive;
}

// Ready means the controller has existed for the settle time, reports possible, and
// its layer has received a frame. Anything the engine handles on its own (no
// controller, a stale generation, an active window) counts as ready.
// When not yet settled, writes the remaining settle interval to `outWait` so the
// caller sleeps once through the settle period instead of polling every 30 ms.
static BOOL CuriumPiPReady(id bridge, uint64_t generation, CFTimeInterval *outWait) {
    if (outWait) {
        *outWait = kCuriumPiPPollSeconds;
    }
    AVPictureInPictureController *controller = object_getIvar(bridge, gCuriumPiPController);
    AVSampleBufferDisplayLayer *layer = object_getIvar(bridge, gCuriumPiPDisplayLayer);
    if (!controller || !layer || controller.isPictureInPictureActive ||
        CuriumPiPActiveGeneration(bridge) != generation) {
        return YES;
    }
    CFTimeInterval now = CACurrentMediaTime();
    NSNumber *firstSeen = objc_getAssociatedObject(controller, &kCuriumPiPFirstSeenKey);
    if (!firstSeen) {
        firstSeen = @(now);
        objc_setAssociatedObject(controller, &kCuriumPiPFirstSeenKey, firstSeen,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CFTimeInterval remainingSettle = kCuriumPiPSettleSeconds - (now - firstSeen.doubleValue);
    if (remainingSettle > 0) {
        if (outWait) {
            *outWait = remainingSettle > kCuriumPiPPollSeconds ? remainingSettle : kCuriumPiPPollSeconds;
        }
        return NO;
    }
    return controller.isPictureInPicturePossible &&
           layer.sampleBufferRenderer.status == AVQueuedSampleBufferRenderingStatusRendering;
}

// Runs action on the main queue once the bridge is ready or the deadline passes.
// Drops the action if the bridge is deallocated meanwhile; its owner is gone too.
static void CuriumPiPWhenReady(id bridge, uint64_t generation, CFTimeInterval startedAt,
                               void (^action)(id bridge, BOOL ready, CFTimeInterval waited)) {
    CFTimeInterval waited = CACurrentMediaTime() - startedAt;
    CFTimeInterval nextWait = kCuriumPiPPollSeconds;
    BOOL ready = CuriumPiPReady(bridge, generation, &nextWait);
    if (ready || waited >= kCuriumPiPReadyDeadlineSeconds) {
        action(bridge, ready, waited);
        return;
    }
    CFTimeInterval remainingDeadline = kCuriumPiPReadyDeadlineSeconds - waited;
    if (nextWait > remainingDeadline) {
        nextWait = remainingDeadline;
    }
    __weak id weakBridge = bridge;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(nextWait * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       id strongBridge = weakBridge;
                       if (strongBridge) {
                           CuriumPiPWhenReady(strongBridge, generation, startedAt, action);
                       }
                   });
}

static void CuriumPiPStart(id self, SEL _cmd, uint64_t generation) {
    CuriumPiPWhenReady(self, generation, CACurrentMediaTime(),
                       ^(id bridge, BOOL ready, CFTimeInterval waited) {
        if (waited > 0) {
            os_log(CuriumPiPLog(), "pip start: held %.0f ms, ready %d", waited * 1000, ready);
        }
        gCuriumPiPEngineStart(bridge, _cmd, generation);
    });
}

static void CuriumPiPFailedToStart(id self, SEL _cmd, AVPictureInPictureController *controller,
                                   NSError *error) {
    uint64_t generation = CuriumPiPActiveGeneration(self);
    if (!CuriumPiPAttemptOpen(self, controller, generation)) {
        gCuriumPiPEngineFailed(self, _cmd, controller, error);
        return;
    }
    CuriumPiPRetryState *state = CuriumPiPRetryStateFor(self, generation);
    if (state.pending) {
        return;
    }
    if (state.count >= kCuriumPiPMaxRetries) {
        gCuriumPiPEngineFailed(self, _cmd, controller, error);
        return;
    }
    state.count += 1;
    state.pending = YES;
    os_log(CuriumPiPLog(), "pip start: retry %lu after %{public}@ %ld",
           (unsigned long)state.count, error.domain, (long)error.code);
    // The engine still counts the attempt as open, so its did-start path accepts the
    // retry. If the bridge moved on meanwhile, the retry is dropped.
    __weak id weakBridge = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kCuriumPiPRetryDelaySeconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       id bridge = weakBridge;
                       if (!bridge) {
                           return;
                       }
                       CuriumPiPWhenReady(bridge, generation, CACurrentMediaTime(),
                                          ^(id readyBridge, BOOL ready, CFTimeInterval waited) {
                           state.pending = NO;
                           if (CuriumPiPAttemptOpen(readyBridge, controller, generation)) {
                               [controller startPictureInPicture];
                           }
                       });
                   });
}

static void CuriumInstallPiPStartWhenReady(Class cls) {
    if (class_getInstanceMethod(cls, sel_registerName("isReadyToStartPiPForGeneration:nextWait:"))) {
        os_log(CuriumPiPLog(), "pip start hook: not needed, engine has native start-when-ready");
        CuriumRecordHookStatus(@"PiP Start-When-Ready", @"skipped",
                               @"Engine provides native start-when-ready");
        return;
    }
    Method start = CuriumExpectMethod(cls, "startPiPForGeneration:", "v24@0:8Q16");
    Method failed = CuriumExpectMethod(
        cls, "pictureInPictureController:failedToStartPictureInPictureWithError:", "v32@0:8@16@24");
    gCuriumPiPController =
        CuriumExpectIvar(cls, "_pipController", "@\"AVPictureInPictureController\"");
    gCuriumPiPDisplayLayer =
        CuriumExpectIvar(cls, "_displayLayer", "@\"AVSampleBufferDisplayLayer\"");
    gCuriumPiPActiveGeneration = CuriumExpectIvar(cls, "_activeGeneration", "Q");
    gCuriumPiPAttemptGeneration = CuriumExpectIvar(cls, "_startAttemptGeneration", "Q");
    gCuriumPiPAttemptActive = CuriumExpectIvar(cls, "_startAttemptActive", "B");
    gCuriumPiPActive = CuriumExpectIvar(cls, "_pipActive", "B");
    // Fail closed: on an unexpected layout, keep the engine's own start path.
    if (!start || !failed || !gCuriumPiPController || !gCuriumPiPDisplayLayer ||
        !gCuriumPiPActiveGeneration || !gCuriumPiPAttemptGeneration ||
        !gCuriumPiPAttemptActive || !gCuriumPiPActive) {
        os_log_error(CuriumPiPLog(), "pip start hook: skipped, unexpected CuriumPiPBridge layout");
        CuriumRecordHookStatus(@"PiP Start-When-Ready", @"failed",
                               @"Unexpected CuriumPiPBridge start layout");
        return;
    }
    gCuriumPiPEngineStart = (CuriumPiPStartIMP)method_setImplementation(start, (IMP)CuriumPiPStart);
    gCuriumPiPEngineFailed =
        (CuriumPiPFailedIMP)method_setImplementation(failed, (IMP)CuriumPiPFailedToStart);
    os_log(CuriumPiPLog(), "pip start hook: installed");
    CuriumRecordHookStatus(@"PiP Start-When-Ready", @"active",
                           @"Readiness gate + 1 retry installed");
}

void CuriumInstallPictureInPictureHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = NSClassFromString(@"CuriumPiPBridge");
        if (!cls) {
            CuriumRecordHookStatus(@"PiP Dealloc Fix", @"skipped",
                                   @"CuriumPiPBridge class not present");
            CuriumRecordHookStatus(@"PiP Start-When-Ready", @"skipped",
                                   @"CuriumPiPBridge class not present");
            return;
        }
        CuriumInstallPiPCloseFix(cls);
        CuriumInstallPiPStartWhenReady(cls);
    });
}
