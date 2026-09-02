//
//  ProxyConfigHelper.m
//  org.waypnt.waypoint.ProxyConfigHelper
//

#import "ProxyConfigHelper.h"
#import <AppKit/AppKit.h>
#import <Security/Security.h>
#import <Security/SecCode.h>
#import <Security/SecStaticCode.h>
#import <sys/types.h> /* audit_token_t */
#import <objc/runtime.h> /* Ivar */
#import "ProxyConfigRemoteProcessProtocol.h"
#import "ProxySettingTool.h"
#import <signal.h>

@interface ProxyConfigHelper()
<
NSXPCListenerDelegate,
ProxyConfigRemoteProcessProtocol
>

@property (nonatomic, strong) NSXPCListener *listener;
@property (nonatomic, strong) NSMutableSet<NSXPCConnection *> *connections;
@property (nonatomic, strong) NSTimer *checkTimer;
@property (nonatomic, assign) BOOL shouldQuit;
@property (nonatomic, strong) NSTask *coreTask;
@property (nonatomic, assign) BOOL killSwitchActive;
@property (nonatomic, assign) BOOL pfWasRunningBeforeUs;

@end

@implementation ProxyConfigHelper
- (instancetype)init {
    
    if (self = [super init]) {
        self.connections = [NSMutableSet new];
        self.shouldQuit = NO;
        self.listener = [[NSXPCListener alloc] initWithMachServiceName:@"org.waypnt.waypoint.ProxyConfigHelper"];
        self.listener.delegate = self;
    }
    return self;
}

- (void)run {
    [self.listener resume];
    self.checkTimer =
    [NSTimer timerWithTimeInterval:5.f target:self selector:@selector(connectionCheckOnLaunch) userInfo:nil repeats:NO];
    [[NSRunLoop currentRunLoop] addTimer:self.checkTimer forMode:NSDefaultRunLoopMode];
    while (!self.shouldQuit) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:2.0]];
    }
    [self clearFirewallState];
    [self stopCoreTask];
}

- (void)connectionCheckOnLaunch {
    if (self.connections.count == 0) {
        // Relaunched with nobody attached: drop any stale kill-switch state a
        // crashed predecessor may have left behind before quitting.
        [self clearFirewallState];
        self.shouldQuit = YES;
    }
}

// MARK: - Connection validation

/// Extracts the connection's audit token. The kernel issues this when the
/// mach connection is established, so it cannot be spoofed or recycled the
/// way a PID can. NSXPCConnection keeps it in a private ivar; try the
/// KVC-visible property first, then read the ivar by offset.
static BOOL WPAuditTokenOfConnection(NSXPCConnection *connection, audit_token_t *outToken) {
    @try {
        id value = [connection valueForKey:@"auditToken"];
        if ([value isKindOfClass:[NSValue class]]) {
            [value getValue:outToken];
            return YES;
        }
    } @catch (NSException *ignored) {}
    Ivar ivar = class_getInstanceVariable([NSXPCConnection class], "_auditToken");
    if (ivar) {
        const uint8_t *base = (const uint8_t *)(__bridge const void *)connection;
        memcpy(outToken, base + ivar_getOffset(ivar), sizeof(audit_token_t));
        return YES;
    }
    return NO;
}

/// Resolves the remote code object. Prefers the audit token; without one,
/// falls back to a PID lookup, which has a small reuse race window.
static SecCodeRef WPCodeForConnection(NSXPCConnection *connection) {
    SecCodeRef code = NULL;
    audit_token_t token = {};
    if (WPAuditTokenOfConnection(connection, &token)) {
        NSData *tokenData = [NSData dataWithBytes:&token length:sizeof(token)];
        NSDictionary *attrs = @{(__bridge id)kSecGuestAttributeAudit: tokenData};
        if (SecCodeCopyGuestWithAttributes(NULL, (__bridge CFDictionaryRef)attrs,
                                           kSecCSDefaultFlags, &code) == errSecSuccess && code) {
            return code;
        }
    }
    NSDictionary *pidAttrs = @{(__bridge id)kSecGuestAttributePid: @(connection.processIdentifier)};
    if (SecCodeCopyGuestWithAttributes(NULL, (__bridge CFDictionaryRef)pidAttrs,
                                       kSecCSDefaultFlags, &code) == errSecSuccess) {
        return code;
    }
    return NULL;
}

/// Returns kSecCodeInfoTeamName for a code object, or nil for unsigned /
/// ad-hoc signed binaries.
// Recent SDKs no longer export the kSecCodeInfoTeamName constant; the
// dictionary key's documented string value is unchanged.
static NSString * const kWPTeamNameKey = @"TeamName";

static NSString *WPTeamIdentifierOfCode(SecCodeRef code) {
    if (!code) { return nil; }
    CFDictionaryRef infoRef = NULL;
    if (SecCodeCopySigningInformation(code, kSecCSSigningInformation, &infoRef) != errSecSuccess || !infoRef) {
        return nil;
    }
    NSDictionary *info = CFBridgingRelease(infoRef);
    NSString *teamName = info[kWPTeamNameKey];
    return [teamName isKindOfClass:NSString.class] ? teamName : nil;
}

- (void)logRejection: (NSXPCConnection *)connection reason:(NSString *)reason {
    fprintf(stderr, "[waypoint-helper] rejected XPC connection from pid %d: %s\n",
            connection.processIdentifier, reason.UTF8String);
}

- (BOOL)connectionIsValid: (NSXPCConnection *)connection {
    SecCodeRef remote = WPCodeForConnection(connection);
    if (!remote) {
        [self logRejection:connection reason:@"could not resolve calling process"];
        return NO;
    }

    NSString *remoteTeam = WPTeamIdentifierOfCode(remote);
    SecCodeRef myCode = NULL;
    NSString *myTeam = nil;
    if (SecCodeCopySelf(kSecCSDefaultFlags, &myCode) == errSecSuccess && myCode) {
        myTeam = WPTeamIdentifierOfCode(myCode);
        CFRelease(myCode);
    }

    // With real distribution signing both sides carry a Team ID and must match.
    if (myTeam.length > 0) {
        CFRelease(remote);
        if (![remoteTeam isEqualToString:myTeam]) {
            [self logRejection:connection
                        reason:[NSString stringWithFormat:@"team identifier mismatch (%@ vs %@)",
                                remoteTeam ?: @"<none>", myTeam]];
            return NO;
        }
        return YES;
    }

    // Helper is ad-hoc/unsigned (development builds): no team identity exists
    // to compare, so fall back to requiring the caller's signing identifier
    // to be our app's. Xcode derives the identifier from the bundle
    // identifier, but old ad-hoc-era builds carried the executable name, so
    // both are accepted. Enforced automatically once the helper carries real
    // distribution signing — the Team ID branch above takes over then.
    static NSString * const kWPOurSigningId = @"org.waypnt.waypoint";
    static NSString * const kWPLegacySigningId = @"Waypoint";
    NSString *remoteSigningId = nil;
    {
        CFDictionaryRef infoRef = NULL;
        if (SecCodeCopySigningInformation(remote, kSecCSSigningInformation, &infoRef) != errSecSuccess || !infoRef) {
            CFRelease(remote);
            [self logRejection:connection reason:@"could not read caller signing information"];
            return NO;
        }
        NSDictionary *info = CFBridgingRelease(infoRef);
        id raw = info[(__bridge id)kSecCodeInfoIdentifier];
        remoteSigningId = [raw isKindOfClass:NSString.class] ? raw : nil;
    }
    CFRelease(remote);

    if (![remoteSigningId isEqualToString:kWPOurSigningId] &&
        ![remoteSigningId isEqualToString:kWPLegacySigningId]) {
        [self logRejection:connection
                    reason:[NSString stringWithFormat:@"signing identifier mismatch (%@ != %@)",
                            remoteSigningId ?: @"<none>", kWPOurSigningId]];
        return NO;
    }
    fprintf(stderr, "[waypoint-helper] WARNING: ad-hoc dev mode — validating callers by "
            "signing identifier only; sign with a real team certificate for full enforcement\n");
    return YES;
}

// MARK: - NSXPCListenerDelegate

- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)newConnection {
    if (![self connectionIsValid:newConnection]) {
        return NO;
    }
    newConnection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(ProxyConfigRemoteProcessProtocol)];
    newConnection.exportedObject = self;
    __weak NSXPCConnection *weakConnection = newConnection;
    __weak ProxyConfigHelper *weakSelf = self;
    newConnection.invalidationHandler = ^{
        [weakSelf.connections removeObject:weakConnection];
        if (weakSelf.connections.count == 0) {
            // Last client gone (quit or crash): never leave the firewall up.
            [weakSelf clearFirewallState];
            weakSelf.shouldQuit = YES;
        }
    };
    [self.connections addObject:newConnection];
    [newConnection resume];
    return YES;
}

// MARK: - ProxyConfigRemoteProcessProtocol
- (void)getVersion:(stringReplyBlock)reply {
    NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if (version == nil) {
        version = @"unknown";
    }
    reply(version);
}

- (void)enableProxyWithPort:(int)port
          socksPort:(int)socksPort
            pac:(NSString *)pac
            filterInterface:(BOOL)filterInterface
                 ignoreList:(NSArray<NSString *>*)ignoreList
            error:(stringReplyBlock)reply {
    dispatch_async(dispatch_get_main_queue(), ^{
        ProxySettingTool *tool = [ProxySettingTool new];
        NSString *error = [tool enableProxyWithport:port socksPort:socksPort pacUrl:pac filterInterface:filterInterface ignoreList:ignoreList];
        reply(error);
    });
}

- (void)disableProxyWithFilterInterface:(BOOL)filterInterface reply:(stringReplyBlock)reply {
    dispatch_async(dispatch_get_main_queue(), ^{
        ProxySettingTool *tool = [ProxySettingTool new];
        NSString *error = [tool disableProxyWithfilterInterface:filterInterface];
        reply(error);
    });
}

- (void)restoreProxyWithCurrentPort:(int)port
                          socksPort:(int)socksPort
                               info:(NSDictionary *)dict
                    filterInterface:(BOOL)filterInterface
                              error:(stringReplyBlock)reply {
    dispatch_async(dispatch_get_main_queue(), ^{
        ProxySettingTool *tool = [ProxySettingTool new];
        NSString *error = [tool restoreProxySetting:dict currentPort:port currentSocksPort:socksPort filterInterface:filterInterface];
        reply(error);
    });
}

- (void)getCurrentProxySetting:(dictReplyBlock)reply {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *info = [ProxySettingTool currentProxySettings];
        reply(info);
    });
}

// MARK: - Root core spawn (TUN mode)

- (void)launchCoreWithBinaryPath:(NSString *)binaryPath
                      configPath:(NSString *)configPath
                         homeDir:(NSString *)homeDir
              externalController:(NSString *)externalController
                          secret:(NSString *)secret
                      externalUI:(NSString *)externalUI
                           reply:(stringReplyBlock)reply {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self stopCoreTask];

        NSMutableArray<NSString *> *args = [NSMutableArray arrayWithArray:@[
            @"-f", configPath,
            @"-d", homeDir,
            @"-ext-ctl", externalController
        ]];
        if (secret.length > 0) {
            [args addObject:@"-secret"];
            [args addObject:secret];
        }
        if (externalUI.length > 0) {
            [args addObject:@"-ext-ui"];
            [args addObject:externalUI];
        }

        NSTask *task = [[NSTask alloc] init];
        task.executableURL = [NSURL fileURLWithPath:binaryPath];
        task.arguments = args;
        task.standardOutput = [NSFileHandle fileHandleForWritingAtPath:@"/dev/null"];
        task.standardError = [NSFileHandle fileHandleForWritingAtPath:@"/dev/null"];

        NSError *launchError = nil;
        if (![task launchAndReturnError:&launchError]) {
            reply(launchError.localizedDescription ?: @"Failed to launch mihomo");
            return;
        }
        self.coreTask = task;
        reply(nil);
    });
}

- (void)stopCore:(stringReplyBlock)reply {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self stopCoreTask];
        reply(nil);
    });
}

- (void)stopCoreTask {
    NSTask *task = self.coreTask;
    self.coreTask = nil;
    if (!task.isRunning) {
        return;
    }
    [task terminate];
    // Wait for the old core to release its listening ports before the caller
    // (launchCore especially) starts a replacement; a relaunch that races a
    // still-dying mihomo fails to bind and dies.
    for (int i = 0; i < 30 && task.isRunning; i++) {
        [NSThread sleepForTimeInterval:0.1];
    }
    if (task.isRunning) {
        kill(task.processIdentifier, SIGKILL);
        [task waitUntilExit];
    }
}

// MARK: - Kill Switch (pf)

static NSString * const kWPAnchorName = @"org.waypnt.waypoint";
static NSString * const kWPAnchorFile = @"/etc/pf.anchors/org.waypnt.waypoint";
static NSString * const kWPPfConfPath = @"/etc/pf.conf";
static NSString * const kWPBeginMark = @"# >>> Waypoint kill switch >>>";
static NSString * const kWPEndMark = @"# <<< Waypoint kill switch <<<";

- (void)setFirewallKillSwitch:(NSString *)rulesText reply:(stringReplyBlock)reply {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.pfWasRunningBeforeUs = [self pfIsEnabled];

        NSError *writeError = nil;
        [rulesText writeToFile:kWPAnchorFile atomically:YES encoding:NSUTF8StringEncoding error:&writeError];
        if (writeError) {
            reply(writeError.localizedDescription ?: @"failed to write anchor file");
            return;
        }

        // Runtime-only load. Never reference the anchor from /etc/pf.conf: a
        // persistent "load anchor" would re-apply the lockout rules at every
        // boot, bricking the network whenever the app (and its teardown) is
        // absent. clearFirewallState still removes blocks left by older builds.
        int loadStatus = 0;
        NSString *output = [self runPfctlWithArgs:@[@"-a", kWPAnchorName, @"-f", kWPAnchorFile] status:&loadStatus];
        if (loadStatus != 0) {
            reply([NSString stringWithFormat:@"pfctl failed: %@", output]);
            return;
        }

        int enableStatus = 0;
        output = [self runPfctlWithArgs:@[@"-e"] status:&enableStatus];
        // "pf already enabled" exits non-zero but is not an error for us.
        if (enableStatus != 0 && ![self pfIsEnabled]) {
            reply([NSString stringWithFormat:@"pfctl failed: %@", output]);
            return;
        }
        self.killSwitchActive = YES;
        reply(nil);
    });
}

- (void)clearFirewallKillSwitch:(stringReplyBlock)reply {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self clearFirewallState];
        reply(nil);
    });
}

/// Synchronous, idempotent teardown — also called from connection-invalidation
/// and daemon-exit paths, not just the XPC entry point.
- (void)clearFirewallState {
    if (self.killSwitchActive) {
        int flushStatus = 0;
        [self runPfctlWithArgs:@[@"-a", kWPAnchorName, @"-F", @"all"] status:&flushStatus];
    }
    self.killSwitchActive = NO;

    NSString *conf = [NSString stringWithContentsOfFile:kWPPfConfPath encoding:NSUTF8StringEncoding error:nil];
    NSRange begin = [conf rangeOfString:kWPBeginMark];
    NSRange end = [conf rangeOfString:kWPEndMark];
    if (begin.location != NSNotFound && end.location != NSNotFound && end.location >= begin.location) {
        NSMutableString *cleaned = [NSMutableString stringWithString:conf];
        [cleaned deleteCharactersInRange:NSMakeRange(begin.location, NSMaxRange(end) - begin.location)];
        // Drop the newline the block introduced.
        while ([cleaned hasSuffix:@"\n\n"]) {
            [cleaned deleteCharactersInRange:NSMakeRange([cleaned length] - 1, 1)];
        }
        [cleaned writeToFile:kWPPfConfPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        int reloadStatus = 0;
        [self runPfctlWithArgs:@[@"-f", kWPPfConfPath] status:&reloadStatus];
    }

    // Only turn pf back off if it was off before we touched it.
    if (!self.pfWasRunningBeforeUs) {
        int disableStatus = 0;
        [self runPfctlWithArgs:@[@"-d"] status:&disableStatus];
        self.pfWasRunningBeforeUs = NO;
    }
}

- (BOOL)pfIsEnabled {
    int status = 0;
    NSString *info = [self runPfctlWithArgs:@[@"-s", @"info"] status:&status];
    return status == 0 && [info rangeOfString:@"Status: Enabled"].location != NSNotFound;
}

- (NSString *)runPfctlWithArgs:(NSArray<NSString *> *)args status:(int *)status {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/sbin/pfctl"];
    task.arguments = args;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    task.standardInput = [NSPipe pipe];
    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        if (status) { *status = -1; }
        return launchError.localizedDescription ?: @"failed to launch pfctl";
    }
    [task waitUntilExit];
    if (status) { *status = task.terminationStatus; }
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}

@end
