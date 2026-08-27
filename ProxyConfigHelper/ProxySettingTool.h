//
//  ProxySettingTool.h
//  org.waypnt.waypoint.ProxyConfigHelper
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ProxySettingTool : NSObject

- (void)enableProxyWithport:(int)port socksPort:(int)socksPort
                     pacUrl:(NSString *)pacUrl
            filterInterface:(BOOL)filterInterface
                 ignoreList:(NSArray<NSString *>*)ignoreList;

- (void)disableProxyWithfilterInterface:(BOOL)filterInterFace;

- (void)restoreProxySetting:(NSDictionary *)savedInfo
                currentPort:(int)port
           currentSocksPort:(int)socksPort
            filterInterface:(BOOL)filterInterface;
+ (NSMutableDictionary<NSString *,NSDictionary *> *)currentProxySettings;

@end

NS_ASSUME_NONNULL_END
