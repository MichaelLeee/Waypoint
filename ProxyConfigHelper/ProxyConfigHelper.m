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

/// Returns the signing Team ID for a code object, or nil for unsigned /
/// ad-hoc signed binaries.
// The Team ID is kSecCodeInfoTeamIdentifier. It is read by string value
// because SecCode.h declares the constant without publishing its literal;
// "teamid" is the documented value and "TeamName" is kept as a fallback
// spelling rather than betting on one.
static NSString * const kWPTeamIdentifierKey = @"teamid";
static NSString * const kWPTeamNameKey = @"TeamName";

static NSString *WPTeamIdentifierOfCode(SecCodeRef code) {
    if (!code) { return nil; }
    CFDictionaryRef infoRef = NULL;
    if (SecCodeCopySigningInformation(code, kSecCSSigningInformation, &infoRef) != errSecSuccess || !infoRef) {
        return nil;
    }
    NSDictionary *info = CFBridgingRelease(infoRef);
    // kSecCodeInfoTeamIdentifier's string value is "teamid"; "TeamName" is kept
    // as a fallback spelling. Reading only "TeamName" made this always return
    // nil, which silently took the Team-ID comparison below out of service.
    NSString *team = info[kWPTeamIdentifierKey];
    if (![team isKindOfClass:NSString.class]) {
        team = info[kWPTeamNameKey];
    }
    return [team isKindOfClass:NSString.class] ? team : nil;
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

    // Helper is ad-hoc/unsigned (development builds): no team identity exists to
    // compare, so fall back to requiring the caller's signing identifier to be
    // our app's. Xcode derives the identifier from the bundle identifier, but
    // old ad-hoc-era builds carried the executable name, so both are accepted.
    // The Team ID branch above takes over automatically once the helper carries
    // real distribution signing.
    //
    // NOT A SECURITY BOUNDARY. A signing identifier is a string anyone can
    // choose: `codesign -s - -i Waypoint /tmp/anything` produces a process that
    // passes this check. What it still does is keep an ordinary, unrelated
    // process from connecting by accident, which is why it is kept rather than
    // removed. Everything reachable from here therefore has to be safe against
    // a hostile local caller on its own — that is the reason
    // `launchCoreWithBinaryPath:` validates its argument instead of trusting it.
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
    fprintf(stderr, "[waypoint-helper] WARNING: ad-hoc dev mode — callers are identified by "
            "signing identifier only, which is spoofable. This is NOT a security boundary; "
            "sign with a real team certificate to get one.\n");
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

// MARK: - Core binary validation

/// The directory of the app bundle this helper ships inside. The helper sits at
/// `<App>.app/Contents/Library/LaunchServices/<helper>`, so mainBundle resolves
/// to the enclosing app; if it somehow does not (a bare executable), walk up
/// from the helper's own path.
static NSString *WPContainingAppPath(void) {
    NSString *bundlePath = [NSBundle mainBundle].bundlePath;
    if ([bundlePath.pathExtension isEqualToString:@"app"]) {
        return bundlePath;
    }
    NSString *dir = [NSBundle mainBundle].executablePath;
    for (int i = 0; i < 6 && dir.length > 1; i++) {
        dir = [dir stringByDeletingLastPathComponent];
        if ([dir.pathExtension isEqualToString:@"app"]) {
            return dir;
        }
    }
    return dir;
}

/// `launchCoreWithBinaryPath:` runs its argument as root, so the path cannot be
/// taken on trust. Two things make that necessary even though XPC callers are
/// checked: the caller check is an ad-hoc signing-*identifier* match, which any
/// local process can satisfy (see the note there), and a path is data rather
/// than identity — a compromised or merely buggy client could otherwise hand
/// over `/tmp/anything` and get it executed with root privileges.
///
/// Only the proxy binary inside this app bundle is accepted, and only when it
/// is not writable by anyone other than the bundle's own owner. That is the
/// meaningful boundary here: substituting the binary requires write access to
/// the app bundle, which the owning user already has (so nothing is gained) but
/// other local accounts and group members do not.
- (BOOL)validateCoreBinaryPath:(NSString *)path error:(NSString **)error {
    if (path.length == 0) {
        if (error) { *error = @"refusing to launch an empty core path"; }
        return NO;
    }

    NSString *resolved = [path stringByResolvingSymlinksInPath];
    NSString *appPath = [WPContainingAppPath() stringByResolvingSymlinksInPath];
    NSString *expected = [[appPath stringByAppendingPathComponent:@"Contents/Resources"]
        stringByAppendingPathComponent:resolved.lastPathComponent];
    if (![resolved isEqualToString:expected]) {
        if (error) {
            *error = [NSString stringWithFormat:
                @"refusing to run %@ as root: the proxy binary must be %@", path, expected];
        }
        return NO;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attrs = [fm attributesOfItemAtPath:resolved error:nil];
    if (!attrs) {
        if (error) { *error = [NSString stringWithFormat:@"proxy binary is missing: %@", resolved]; }
        return NO;
    }
    if (![fm isExecutableFileAtPath:resolved]) {
        if (error) { *error = [NSString stringWithFormat:@"proxy binary is not executable: %@", resolved]; }
        return NO;
    }

    NSUInteger mode = [attrs[NSFilePosixPermissions] unsignedIntegerValue];
    if ((mode & 0x12) != 0) { // 0o020 group write, 0o002 other write
        if (error) {
            *error = [NSString stringWithFormat:
                @"refusing to run %@ as root: it is writable by group or others (mode %o)",
                resolved, (unsigned)mode];
        }
        return NO;
    }

    NSUInteger owner = [attrs[NSFileOwnerAccountID] unsignedIntegerValue];
    NSDictionary *bundleAttrs = [fm attributesOfItemAtPath:appPath error:nil];
    NSUInteger bundleOwner = [bundleAttrs[NSFileOwnerAccountID] unsignedIntegerValue];
    if (owner != bundleOwner) {
        if (error) {
            *error = [NSString stringWithFormat:
                @"refusing to run %@ as root: it is owned by uid %lu but the app bundle by uid %lu",
                resolved, (unsigned long)owner, (unsigned long)bundleOwner];
        }
        return NO;
    }

    return YES;
}

- (void)launchCoreWithBinaryPath:(NSString *)binaryPath
                      configPath:(NSString *)configPath
                         homeDir:(NSString *)homeDir
              externalController:(NSString *)externalController
                          secret:(NSString *)secret
                      externalUI:(NSString *)externalUI
                           reply:(stringReplyBlock)reply {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self stopCoreTask];

        NSString *pathError = nil;
        if (![self validateCoreBinaryPath:binaryPath error:&pathError]) {
            reply(pathError);
            return;
        }

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

        // /etc/pf.anchors is present on a stock macOS, but the atomic write
        // below fails with a bare "no such file" if it is not, which reads like
        // a kill-switch bug rather than a missing directory.
        [[NSFileManager defaultManager] createDirectoryAtPath:[kWPAnchorFile stringByDeletingLastPathComponent]
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];

        NSError *writeError = nil;
        [rulesText writeToFile:kWPAnchorFile atomically:YES encoding:NSUTF8StringEncoding error:&writeError];
        if (writeError) {
            reply(writeError.localizedDescription ?: @"failed to write anchor file");
            return;
        }

        int enableStatus = 0;
        NSString *output = [self runPfctlWithArgs:@[@"-e"] status:&enableStatus];
        // "pf already enabled" exits non-zero but is not an error for us.
        if (enableStatus != 0 && ![self pfIsEnabled]) {
            reply([NSString stringWithFormat:@"pfctl failed: %@", output]);
            return;
        }

        // The anchor has to be *referenced* by the main ruleset or pf never
        // evaluates it: `pfctl -a name -f file` only loads rules into the named
        // anchor, it does not put the anchor in the evaluation path. Without the
        // reference in pf.conf the previously loaded rules sat there unused and
        // the switch silently protected nothing — it failed open.
        //
        // A bare `anchor "name"` is the safe form: unlike `load anchor`, it
        // reads no file at boot, so after a restart it references an empty
        // anchor and drops nothing. The rules themselves are loaded at runtime
        // below and do not survive a reboot. clearFirewallState removes this
        // block again on teardown.
        NSString *referenceError = [self installPfConfAnchorReference];
        if (referenceError) {
            reply(referenceError);
            return;
        }

        // After the reference, so that reloading pf.conf cannot drop the freshly
        // loaded rules: `pfctl -f` re-reads the main ruleset and the anchors it
        // mentions.
        int loadStatus = 0;
        output = [self runPfctlWithArgs:@[@"-a", kWPAnchorName, @"-f", kWPAnchorFile] status:&loadStatus];
        if (loadStatus != 0) {
            reply([NSString stringWithFormat:@"pfctl failed: %@", output]);
            return;
        }

        self.killSwitchActive = YES;
        reply(nil);
    });
}

/// Adds a marker-delimited `anchor "org.waypnt.waypoint"` line to /etc/pf.conf
/// and reloads it. Returns nil on success (including "already present"),
/// otherwise a message for the caller. Keeps a one-time backup of pf.conf.
- (NSString *)installPfConfAnchorReference {
    NSString *conf = [NSString stringWithContentsOfFile:kWPPfConfPath
                                               encoding:NSUTF8StringEncoding
                                                  error:nil];
    if (!conf) {
        return [NSString stringWithFormat:@"failed to read %@", kWPPfConfPath];
    }
    if ([conf rangeOfString:kWPBeginMark].location != NSNotFound) {
        return nil;
    }

    NSMutableString *updated = [NSMutableString stringWithString:conf];
    if (![updated hasSuffix:@"\n"]) {
        [updated appendString:@"\n"];
    }
    [updated appendFormat:@"%@\nanchor \"%@\"\n%@\n", kWPBeginMark, kWPAnchorName, kWPEndMark];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *backup = [kWPPfConfPath stringByAppendingPathExtension:@"waypoint-backup"];
    if (![fm fileExistsAtPath:backup]) {
        [conf writeToFile:backup atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }

    NSError *writeError = nil;
    if (![updated writeToFile:kWPPfConfPath atomically:YES encoding:NSUTF8StringEncoding error:&writeError]) {
        return writeError.localizedDescription ?: @"failed to update pf.conf";
    }

    int reloadStatus = 0;
    NSString *output = [self runPfctlWithArgs:@[@"-f", kWPPfConfPath] status:&reloadStatus];
    if (reloadStatus != 0) {
        // Put the original back rather than leave a reference pf cannot parse.
        [conf writeToFile:kWPPfConfPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        int restoreStatus = 0;
        [self runPfctlWithArgs:@[@"-f", kWPPfConfPath] status:&restoreStatus];
        return [NSString stringWithFormat:@"pf.conf rejected the kill-switch anchor: %@", output];
    }
    return nil;
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
    // Unconditional: killSwitchActive is in-memory only, so a helper killed
    // while the switch was up (crash, SIGKILL, kickstart) left the anchor
    // loaded with nothing to clear it. This runs on launch precisely to clean
    // up after such a predecessor, and flushing an anchor that holds no rules
    // is a no-op.
    int flushStatus = 0;
    [self runPfctlWithArgs:@[@"-a", kWPAnchorName, @"-F", @"all"] status:&flushStatus];
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
