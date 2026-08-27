//
//  CommonUtils.h
//  Waypoint
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CommonUtils : NSObject
+ (NSString *)runCommand:(NSString *)path args:(nullable NSArray *)args;
@end

NS_ASSUME_NONNULL_END
