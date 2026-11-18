#import <Foundation/Foundation.h>

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
@end

@interface CrIOSExtensionManagerV1 : NSObject <CrIOSExtensionManagingV1>
+ (instancetype)sharedManager;
@end
