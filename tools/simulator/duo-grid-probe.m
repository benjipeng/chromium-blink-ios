// Simulator-only receipt for the current tab grid and UIKit's reserved regions.
#import <UIKit/UIKit.h>
#import <notify.h>

static NSArray<NSNumber *> *Coordinates(CGRect rect) {
  return @[@(CGRectGetMinX(rect)), @(CGRectGetMinY(rect)),
           @(CGRectGetMaxX(rect)), @(CGRectGetMaxY(rect))];
}

static void CollectCards(UIView *view, UIWindow *window,
                         NSMutableArray<NSDictionary *> *cards) {
  if (view.isHidden || view.alpha <= 0.01) return;
  NSString *name = view.accessibilityIdentifier;
  if ([name hasPrefix:@"GridCellIdentifierPrefix"]) {
    CGRect frame = [view convertRect:view.bounds toView:window];
    if (CGRectIntersectsRect(window.bounds, frame)) {
      [cards addObject:@{@"id": name, @"frame": Coordinates(frame)}];
    }
    return;
  }
  for (UIView *child in view.subviews) {
    CollectCards(child, window, cards);
  }
}

static void WriteReceipt(void) {
  NSMutableArray<NSDictionary *> *windows = [NSMutableArray array];
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:UIWindowScene.class] ||
        scene.activationState != UISceneActivationStateForegroundActive) {
      continue;
    }
    for (UIWindow *window in ((UIWindowScene *)scene).windows) {
      if (window.isHidden) continue;
      NSMutableArray<NSDictionary *> *cards = [NSMutableArray array];
      CollectCards(window, window, cards);
      if (cards.count == 0) continue;

      NSMutableArray<NSArray<NSNumber *> *> *divisions = [NSMutableArray array];
      if (@available(iOS 27.1, *)) {
        for (UIViewReservedRegion *region in [window
                 reservedRegionsOfKind:UIViewReservedRegionKind.divisionRegionKind]) {
          if (region.isActive) [divisions addObject:Coordinates(region.frame)];
        }
      }
      [windows addObject:@{@"visibleBounds": Coordinates(window.bounds),
                           @"divisions": divisions,
                           @"cards": cards}];
    }
  }
  NSData *receipt = [NSJSONSerialization dataWithJSONObject:windows
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:nil];
  [receipt writeToFile:[NSTemporaryDirectory() stringByAppendingPathComponent:
                @"duo-grid-receipt.json"] atomically:YES];
}

__attribute__((constructor))
static void ObserveCaptureRequest(void) {
  int token;
  notify_register_dispatch("org.chromium.blink.ios.duo-grid.capture", &token,
                           dispatch_get_main_queue(), ^(__unused int value) {
    WriteReceipt();
  });
}
