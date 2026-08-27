//
//  ProxyConfigRemoteProcessProtocol.h
//  org.waypnt.waypoint.ProxyConfigHelper
//

@import Foundation;

typedef void(^stringReplyBlock)(NSString *);
typedef void(^boolReplyBlock)(BOOL);
typedef void(^dictReplyBlock)(NSDictionary *);

@protocol ProxyConfigRemoteProcessProtocol <NSObject>
@required

- (void)getVersion:(stringReplyBlock)reply;

- (void)enableProxyWithPort:(int)port
                  socksPort:(int)socksPort
                        pac:(NSString *)pac
            filterInterface:(BOOL)filterInterface
                 ignoreList:(NSArray<NSString *>*)ignoreList
                      error:(stringReplyBlock)reply;

- (void)disableProxyWithFilterInterface:(BOOL)filterInterface
                                  reply:(stringReplyBlock)reply;

- (void)restoreProxyWithCurrentPort:(int)port
                          socksPort:(int)socksPort
                               info:(NSDictionary *)dict
                    filterInterface:(BOOL)filterInterface
                              error:(stringReplyBlock)reply;

- (void)getCurrentProxySetting:(dictReplyBlock)reply;

// Root core spawn (TUN mode). `reply(nil)` on success, otherwise an error
// string. The helper owns the spawned NSTask and tears it down on stop/exit so
// a root mihomo with TUN routes is never orphaned.
- (void)launchCoreWithBinaryPath:(NSString *)binaryPath
                      configPath:(NSString *)configPath
                         homeDir:(NSString *)homeDir
              externalController:(NSString *)externalController
                          secret:(NSString *)secret
                      externalUI:(NSString *)externalUI
                           reply:(stringReplyBlock)reply;

- (void)stopCore:(stringReplyBlock)reply;

// Kill Switch (pf). `reply(nil)` on success, otherwise an error string. The
// helper owns the anchor file, the pf.conf anchor block, and pf's enabled
// state; it removes all of it automatically when the app disconnects, when the
// daemon sits idle after a relaunch, and before it exits — so a crash can
// never leave the machine without network.
- (void)setFirewallKillSwitch:(NSString *)rulesText reply:(stringReplyBlock)reply;

- (void)clearFirewallKillSwitch:(stringReplyBlock)reply;
@end
