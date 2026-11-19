#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

NS_SWIFT_UI_ACTOR
@protocol CrIOSExtensionPopupHostingV1 <NSObject>

@property (nonatomic, copy, readonly) NSString *extensionID;
@property (nonatomic, readonly) int32_t tabID;
@property (nonatomic, strong, readonly) UIView *view;
/// The preferred popup size in UIKit points.
@property (nonatomic, readonly) CGSize preferredContentSize;
/// A request from the extension for the shell to dismiss the popup.
@property (nonatomic, copy, nullable) void (^NS_SWIFT_UI_ACTOR onRequestClose)(void);

/// Releases the engine's popup resources. Safe to call more than once.
- (void)close;

@end

NS_ASSUME_NONNULL_END

// The legacy declarations retain the nullability and Swift import behavior
// of the existing extensions UI header.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"
@protocol CrIOSExtensionManagingV1 <NSObject>
- (NSArray<NSDictionary<NSString *, id> *> *)extensionsWithError:
    (NSError *__autoreleasing *)error;
- (BOOL)setExtensionWithID:(NSString *)extensionId
                   enabled:(BOOL)enabled
                     error:(NSError *__autoreleasing *)error;
@optional
- (void)uninstallExtensionWithID:(NSString *)extensionID
                      completion:(void (^)(BOOL removed, NSError *error))completion;
- (void)prepareStoreExtensionWithID:(NSString *)storeID
                          completion:
                              (void (^)(NSDictionary<NSString *, id> *prepared,
                                        NSError *error))completion;
- (void)prepareSignedExtensionAtPath:(NSString *)path
                          completion:
                              (void (^)(NSDictionary<NSString *, id> *prepared,
                                        NSError *error))completion;
- (void)confirmPreparedExtensionWithToken:(NSString *)token
                               completion:(void (^)(NSDictionary<NSString *, id>
                                                        *extension,
                                                    NSError *error))completion;
- (BOOL)cancelPreparedExtensionWithToken:(NSString *)token
                                   error:(NSError *__autoreleasing *)error;
#pragma clang diagnostic pop

NS_ASSUME_NONNULL_BEGIN

/// Returns a toolbar snapshot for the given tab. See README.md for its keys.
- (nullable NSDictionary<NSString *, id> *)
    actionPresentationForExtensionWithID:(NSString *)extensionID
                                    tabID:(int32_t)tabID
                                    error:(NSError *__autoreleasing _Nullable *_Nullable)error
    NS_SWIFT_UI_ACTOR;

/// Retain the observation token for as long as updates are needed. A nil
/// extension ID invalidates all snapshots.
- (nullable id<NSObject>)observeActionPresentationChangesWithHandler:
    (void (^NS_SWIFT_UI_ACTOR)(NSString *_Nullable extensionID))handler
    NS_SWIFT_UI_ACTOR;

/// Returns the tab's declarativeNetRequest block count, including zero.
- (nullable NSNumber *)blockedRequestCountForExtensionWithID:(NSString *)extensionID
                                                       tabID:(int32_t)tabID
                                                       error:(NSError *__autoreleasing _Nullable *_Nullable)error
    NS_SWIFT_UI_ACTOR;

- (nullable id<CrIOSExtensionPopupHostingV1>)popupForExtensionWithID:(NSString *)extensionID
                                                             tabID:(int32_t)tabID
                                                             error:(NSError *__autoreleasing _Nullable *_Nullable)error
    NS_SWIFT_UI_ACTOR;

/// Returns the extension's command dictionaries. See README.md for their keys.
- (nullable NSArray<NSDictionary<NSString *, NSString *> *> *)
    commandsForExtensionWithID:(NSString *)extensionID
                          error:(NSError *__autoreleasing _Nullable *_Nullable)error
    NS_SWIFT_UI_ACTOR;
- (BOOL)dispatchCommandNamed:(NSString *)commandName
           toExtensionWithID:(NSString *)extensionID
                       error:(NSError *__autoreleasing _Nullable *_Nullable)error
    NS_SWIFT_UI_ACTOR;

NS_ASSUME_NONNULL_END

@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"
@interface CrIOSExtensionManagerV1 : NSObject <CrIOSExtensionManagingV1>
+ (instancetype)sharedManager;
@end
#pragma clang diagnostic pop
