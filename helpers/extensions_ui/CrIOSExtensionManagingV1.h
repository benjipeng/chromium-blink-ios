#import <Foundation/Foundation.h>

@protocol CrIOSExtensionManagingV1 <NSObject>
- (NSArray<NSDictionary<NSString *, id> *> *)extensionsWithError:
    (NSError *__autoreleasing *)error;
- (BOOL)setExtensionWithID:(NSString *)extensionId
                   enabled:(BOOL)enabled
                     error:(NSError *__autoreleasing *)error;
@end

@interface CrIOSExtensionManagerV1 : NSObject <CrIOSExtensionManagingV1>
+ (instancetype)sharedManager;
@end
