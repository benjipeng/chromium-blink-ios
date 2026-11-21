#import "CuriumTouchCancelHook.h"
#import "CuriumHookSupport.h"
#import <UIKit/UIKit.h>
#import <os/log.h>

// Blink iOS's RenderWidgetUIView forwards touchesCancelled:withEvent: one
// UITouch at a time to input::WebTouchEventBuilder::Build(kTouchCancel, ...).
// WebTouchEventBuilder tracks active UITouches in a process-global 16-slot
// array: after removing the single passed touch, it appends every remaining
// touch in that global array with changed=false (WebTouchPoint::kStateStationary).
// content::MotionEventWeb::MotionEventWeb() then checks
// DCHECK(WebTouchEventTraits::AllTouchPointsHaveState(event, kStateCancelled))
// and traps with SIGTRAP whenever a second touch is active (multi-touch cancel,
// partial touch cancel, or a stale touch left over from another view).
// WebTouchEventBuilder also traps if kTouchEnd/kTouchCancel receives an
// untracked UITouch or if kTouchStart receives a duplicate UITouch.
//
// This hook mirrors the 16-slot global touch set across RenderWidgetUIView
// instances on the main thread. When touchesCancelled:withEvent: arrives while
// more than one touch is active (or a touch's phase is not Cancelled), extra
// touches are first lifted via the original touchesEnded:withEvent: (which
// emits ACTION_POINTER_UP without violating MotionEventWeb's kTouchCancel
// invariant). Only the final touch—when it is the sole entry remaining in the
// global table and has UITouchPhaseCancelled—is delivered to the original
// touchesCancelled:withEvent:.

typedef void (*CuriumTouchHandlerIMP)(id, SEL, NSSet<UITouch *> *, UIEvent *);

static const NSUInteger kWebTouchBuilderCapacity = 16;

static CuriumTouchHandlerIMP gOrigTouchesBegan;
static CuriumTouchHandlerIMP gOrigTouchesMoved;
static CuriumTouchHandlerIMP gOrigTouchesEnded;
static CuriumTouchHandlerIMP gOrigTouchesCancelled;

static os_log_t CuriumTouchHookLog(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.appautomaton.curium", "engine");
    });
    return log;
}

static NSMutableArray<UITouch *> *CuriumTrackedTouches(void) {
    static NSMutableArray<UITouch *> *tracked;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        tracked = [NSMutableArray arrayWithCapacity:kWebTouchBuilderCapacity];
    });
    return tracked;
}

static NSUInteger CuriumFindTrackedTouch(NSMutableArray<UITouch *> *tracked, UITouch *target) {
    NSUInteger count = tracked.count;
    for (NSUInteger i = 0; i < count; i++) {
        if (tracked[i] == target) {
            return i;
        }
    }
    return NSNotFound;
}

static BOOL CuriumIsTouchStale(UITouch *touch) {
    UITouchPhase phase = touch.phase;
    return touch.window == nil ||
           phase == UITouchPhaseEnded ||
           phase == UITouchPhaseCancelled;
}

static void CuriumRemoveTouches(NSMutableArray<UITouch *> *tracked, NSArray<UITouch *> *toRemove) {
    for (UITouch *touch in toRemove) {
        NSUInteger idx = CuriumFindTrackedTouch(tracked, touch);
        if (idx != NSNotFound) {
            [tracked removeObjectAtIndex:idx];
        }
    }
}

static void CuriumTouchesBegan(id self, SEL _cmd, NSSet<UITouch *> *touches, UIEvent *event) {
    NSMutableArray<UITouch *> *tracked = CuriumTrackedTouches();

    // If the 16-slot table is full, reclaim any stale touches before admitting new ones.
    if (tracked.count >= kWebTouchBuilderCapacity) {
        NSMutableArray<UITouch *> *stale = [NSMutableArray array];
        for (UITouch *t in tracked) {
            if (CuriumIsTouchStale(t)) {
                [stale addObject:t];
            }
        }
        if (stale.count > 0) {
            CuriumRemoveTouches(tracked, stale);
            gOrigTouchesEnded(self, @selector(touchesEnded:withEvent:),
                              [NSSet setWithArray:stale], event);
        }
    }

    NSMutableSet<UITouch *> *admitted = [NSMutableSet setWithCapacity:touches.count];
    for (UITouch *touch in touches) {
        if (tracked.count >= kWebTouchBuilderCapacity) {
            break;
        }
        if (CuriumFindTrackedTouch(tracked, touch) == NSNotFound) {
            [tracked addObject:touch];
            [admitted addObject:touch];
        }
    }
    if (admitted.count > 0) {
        gOrigTouchesBegan(self, _cmd, admitted, event);
    }
}

static void CuriumTouchesMoved(id self, SEL _cmd, NSSet<UITouch *> *touches, UIEvent *event) {
    NSMutableArray<UITouch *> *tracked = CuriumTrackedTouches();
    NSMutableSet<UITouch *> *known = [NSMutableSet setWithCapacity:touches.count];
    for (UITouch *touch in touches) {
        if (CuriumFindTrackedTouch(tracked, touch) != NSNotFound) {
            [known addObject:touch];
        }
    }
    if (known.count > 0) {
        gOrigTouchesMoved(self, _cmd, known, event);
    }
}

static void CuriumTouchesEnded(id self, SEL _cmd, NSSet<UITouch *> *touches, UIEvent *event) {
    NSMutableArray<UITouch *> *tracked = CuriumTrackedTouches();
    NSMutableArray<UITouch *> *ending = [NSMutableArray arrayWithCapacity:touches.count];
    for (UITouch *touch in touches) {
        if (CuriumFindTrackedTouch(tracked, touch) != NSNotFound) {
            [ending addObject:touch];
        }
    }
    CuriumRemoveTouches(tracked, ending);
    gOrigTouchesEnded(self, _cmd,
                      ending.count > 0 ? [NSSet setWithArray:ending] : [NSSet set],
                      event);
}

static void CuriumTouchesCancelled(id self, SEL _cmd, NSSet<UITouch *> *touches, UIEvent *event) {
    NSMutableArray<UITouch *> *tracked = CuriumTrackedTouches();
    NSMutableArray<UITouch *> *toCancel = [NSMutableArray arrayWithCapacity:touches.count];
    for (UITouch *touch in touches) {
        if (CuriumFindTrackedTouch(tracked, touch) != NSNotFound) {
            [toCancel addObject:touch];
        }
    }

    // Drain any stale touches left over from another view or earlier sequence so
    // they cannot remain in WebTouchEventBuilder's global table as kStateStationary.
    NSMutableArray<UITouch *> *staleOthers = [NSMutableArray array];
    for (UITouch *existing in tracked) {
        if (CuriumFindTrackedTouch(toCancel, existing) == NSNotFound &&
            CuriumIsTouchStale(existing)) {
            [staleOthers addObject:existing];
        }
    }
    if (staleOthers.count > 0) {
        CuriumRemoveTouches(tracked, staleOthers);
        gOrigTouchesEnded(self, @selector(touchesEnded:withEvent:),
                          [NSSet setWithArray:staleOthers], event);
    }

    if (toCancel.count == 0) {
        // Still run RenderWidgetUIView's post-loop reset (_viewOffsetDuringTouchSequence
        // and longPressDidEndShowingMenu:NO).
        gOrigTouchesCancelled(self, _cmd, [NSSet set], event);
        return;
    }

    // MotionEventWeb requires every touch point in a kTouchCancel WebTouchEvent
    // to have kStateCancelled. That holds iff WebTouchEventBuilder's global table
    // becomes empty when the touch is removed and [touch phase] == Cancelled.
    UITouch *lastTouch = toCancel.lastObject;
    BOOL canEmitFinalCancel =
        (toCancel.count == tracked.count) &&
        (lastTouch.phase == UITouchPhaseCancelled);

    if (canEmitFinalCancel) {
        if (toCancel.count > 1) {
            NSArray<UITouch *> *prefix =
                [toCancel subarrayWithRange:NSMakeRange(0, toCancel.count - 1)];
            CuriumRemoveTouches(tracked, prefix);
            gOrigTouchesEnded(self, @selector(touchesEnded:withEvent:),
                              [NSSet setWithArray:prefix], event);
        }
        CuriumRemoveTouches(tracked, @[lastTouch]);
        gOrigTouchesCancelled(self, _cmd, [NSSet setWithObject:lastTouch], event);
        return;
    }

    // Either another live touch remains active (partial cancel) or the touch's
    // phase is not UITouchPhaseCancelled. Lift the cancelled touches cleanly as
    // ACTION_POINTER_UP / ACTION_UP, then run RenderWidgetUIView's cancel cleanup.
    CuriumRemoveTouches(tracked, toCancel);
    gOrigTouchesEnded(self, @selector(touchesEnded:withEvent:),
                      [NSSet setWithArray:toCancel], event);
    gOrigTouchesCancelled(self, _cmd, [NSSet set], event);
}

void CuriumInstallTouchCancelHook(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        os_log_t log = CuriumTouchHookLog();
        Class cls = NSClassFromString(@"RenderWidgetUIView");
        const char *sig = "v32@0:8@16@24";
        Method mBegan     = cls ? CuriumExpectMethod(cls, "touchesBegan:withEvent:", sig) : NULL;
        Method mMoved     = cls ? CuriumExpectMethod(cls, "touchesMoved:withEvent:", sig) : NULL;
        Method mEnded     = cls ? CuriumExpectMethod(cls, "touchesEnded:withEvent:", sig) : NULL;
        Method mCancelled = cls ? CuriumExpectMethod(cls, "touchesCancelled:withEvent:", sig) : NULL;
        if (!mBegan || !mMoved || !mEnded || !mCancelled) {
            os_log_error(log, "touch cancel hook: skipped, unexpected RenderWidgetUIView methods");
            return;
        }
        gOrigTouchesBegan     = (CuriumTouchHandlerIMP)method_setImplementation(mBegan, (IMP)CuriumTouchesBegan);
        gOrigTouchesMoved     = (CuriumTouchHandlerIMP)method_setImplementation(mMoved, (IMP)CuriumTouchesMoved);
        gOrigTouchesEnded     = (CuriumTouchHandlerIMP)method_setImplementation(mEnded, (IMP)CuriumTouchesEnded);
        gOrigTouchesCancelled = (CuriumTouchHandlerIMP)method_setImplementation(mCancelled, (IMP)CuriumTouchesCancelled);
        os_log(log, "touch cancel hook: installed on RenderWidgetUIView");
    });
}
