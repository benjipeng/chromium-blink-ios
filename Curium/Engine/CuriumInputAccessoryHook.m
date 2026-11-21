#import "CuriumInputAccessoryHook.h"
#import "CuriumHookSupport.h"
#import <GameController/GameController.h>
#import <UIKit/UIKit.h>
#import <os/log.h>

// RenderWidgetUIView, the engine's text input view, returns a UIToolbar as its
// inputAccessoryView: previous and next field, then done. Above the on-screen
// keyboard that is right. With a hardware keyboard, UIKit docks the accessory alone
// at the bottom edge, 8 pt above it, where its glass pills collide with the display
// corners and with Curium's bottom chrome. Tab, Shift-Tab, and Escape already cover
// its three actions, so while a hardware keyboard is attached the view returns no
// accessory, and a keyboard connecting or disconnecting mid-edit reloads the input
// views so the change applies at once.

typedef UIView *(*CuriumInputAccessoryIMP)(id, SEL);

static CuriumInputAccessoryIMP gCuriumEngineInputAccessoryView;
static SEL gCuriumReloadInputViews;

static UIView *CuriumInputAccessoryView(id self, SEL _cmd) {
    if (GCKeyboard.coalescedKeyboard) {
        return nil;
    }
    return gCuriumEngineInputAccessoryView(self, _cmd);
}

static void CuriumReloadInputViews(UIResponder *self, SEL _cmd) {
    [self reloadInputViews];
}

static void CuriumReloadFirstResponderInputViews(void) {
    // Reaches the first responder only; elsewhere the action is simply unhandled.
    [UIApplication.sharedApplication sendAction:gCuriumReloadInputViews
                                             to:nil
                                           from:nil
                                       forEvent:nil];
}

void CuriumInstallInputAccessoryHook(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        os_log_t log = os_log_create("com.appautomaton.curium", "engine");
        Class cls = NSClassFromString(@"RenderWidgetUIView");
        Method method = cls ? CuriumExpectMethod(cls, "inputAccessoryView", "@16@0:8") : NULL;
        gCuriumReloadInputViews = sel_registerName("curium_reloadInputViews");
        // Fail closed: on an unexpected layout, keep the engine's accessory.
        if (!method || !class_addMethod(cls, gCuriumReloadInputViews,
                                        (IMP)CuriumReloadInputViews, "v16@0:8")) {
            os_log_error(log, "input accessory hook: skipped, unexpected RenderWidgetUIView");
            return;
        }
        gCuriumEngineInputAccessoryView = (CuriumInputAccessoryIMP)method_setImplementation(
            method, (IMP)CuriumInputAccessoryView);
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        for (NSNotificationName name in @[GCKeyboardDidConnectNotification,
                                          GCKeyboardDidDisconnectNotification]) {
            [center addObserverForName:name
                                object:nil
                                 queue:NSOperationQueue.mainQueue
                            usingBlock:^(NSNotification *note) {
                                os_log(log, "input accessory hook: hardware keyboard %{public}s",
                                       [note.name isEqualToString:GCKeyboardDidConnectNotification]
                                           ? "connected" : "disconnected");
                                CuriumReloadFirstResponderInputViews();
                            }];
        }
        os_log(log, "input accessory hook: installed");
    });
}
