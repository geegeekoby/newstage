#import "DSBootstrap.h"
#import "DSConstants.h"
#import "DSExclusions.h"
#import <fcntl.h>
#import <unistd.h>
#import <string.h>
#import <stdlib.h>
#import <stdio.h>

static const char *kDSGuardPaths[] = {
    "/var/mobile/Library/Preferences/com.recreated.dynamicstage.launchguard",
    "/var/tmp/com.recreated.dynamicstage.launchguard",
};

static const char *kDSKillSwitchPaths[] = {
    "/var/mobile/.dynamicstage-disabled",
    "/var/jb/var/mobile/.dynamicstage-disabled",
    "/var/tmp/.dynamicstage-disabled",
};

static int DSReadCountAt(const char *path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return 0;
    char buffer[16] = {0};
    ssize_t n = read(fd, buffer, sizeof(buffer) - 1);
    close(fd);
    if (n <= 0) return 0;
    return atoi(buffer);
}

static void DSWriteCountAt(const char *path, int count) {
    if (count <= 0) {
        unlink(path);
        return;
    }
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return;
    char buffer[16];
    int len = snprintf(buffer, sizeof(buffer), "%d\n", count);
    if (len > 0) {
        ssize_t ignored __attribute__((unused)) = write(fd, buffer, (size_t)len);
    }
    close(fd);
}

static int DSLaunchGuardCount(void) {
    int max = 0;
    for (size_t i = 0; i < sizeof(kDSGuardPaths) / sizeof(kDSGuardPaths[0]); i++) {
        int value = DSReadCountAt(kDSGuardPaths[i]);
        if (value > max) max = value;
    }
    return max;
}

static void DSSetLaunchGuardCount(int count) {
    for (size_t i = 0; i < sizeof(kDSGuardPaths) / sizeof(kDSGuardPaths[0]); i++) {
        DSWriteCountAt(kDSGuardPaths[i], count);
    }
}

bool DSKillSwitchPresent(void) {
    for (size_t i = 0; i < sizeof(kDSKillSwitchPaths) / sizeof(kDSKillSwitchPaths[0]); i++) {
        if (access(kDSKillSwitchPaths[i], F_OK) == 0) return true;
    }
    return false;
}

bool DSLaunchGuardTripped(void) {
    return DSLaunchGuardCount() >= kDSMaxUncleanLaunches;
}

bool DSBootstrapBeginFullInstall(void) {
    if (DSKillSwitchPresent()) return false;
    int count = DSLaunchGuardCount();
    if (count >= kDSMaxUncleanLaunches) return false;
    DSSetLaunchGuardCount(count + 1);
    return true;
}

void DSBootstrapMarkLaunchSucceeded(void) {
    DSSetLaunchGuardCount(0);
}

bool DSBundleLooksLikeUserApplication(void) {
    NSString *path = NSBundle.mainBundle.bundlePath;
    if (path.length == 0) return false;

    NSString *identifier = NSBundle.mainBundle.bundleIdentifier;
    if (DSIdentifierIsExcludedFromStage(identifier)) return false;

    NSString *lower = path.lowercaseString;
    for (NSString *needle in @[ @"keyboardarbiter", @"springboard", @"preferencebundles",
                                @"tweakinject", @"mobilesubstrate", @"ellekit" ]) {
        if ([lower rangeOfString:needle].location != NSNotFound) return false;
    }

    for (NSString *prefix in @[ @"/System", @"/usr", @"/bin", @"/sbin", @"/Library",
                                @"/private/preboot", @"/var/jb/usr", @"/var/jb/Library",
                                @"/var/jb/System", @"/cores" ]) {
        if ([path hasPrefix:prefix]) return false;
    }

    return [path hasPrefix:@"/var/containers"] ||
           [path hasPrefix:@"/private/var/containers"] ||
           [path hasPrefix:@"/Applications"] ||
           [path hasPrefix:@"/var/jb/Applications"] ||
           [path hasPrefix:@"/private/var/jb/Applications"] ||
           [path hasPrefix:@"/var/jb/var/containers"];
}
