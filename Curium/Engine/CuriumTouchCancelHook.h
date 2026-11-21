#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Guards RenderWidgetUIView touch delivery against Blink iOS's multi-touch
// cancellation DCHECK in content::MotionEventWeb (and WebTouchEventBuilder's
// 16-slot global touch table checks).
void CuriumInstallTouchCancelHook(void);

NS_ASSUME_NONNULL_END
