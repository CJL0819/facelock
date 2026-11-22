// SPDX-License-Identifier: MIT
//
// Shared between the tweak that guards an app and the Settings pane that
// picks the apps: one preferences domain, one key per protected bundle id,
// one Darwin notification after a change, and the two names a lock screen and
// SpringBoard's auth service talk over.
#pragma once

#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>

/// The preferences domain, the package id this build produced. The pane
/// writes there through cfprefsd; the tweak reads the same values.
static inline NSString *APLPreferencesDomain(void) {
    static NSString *domain;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        domain = [NSString stringWithUTF8String:APELIN_PACKAGE_ID];
    });
    return domain;
}

/// Posted by the pane after a row changes, so a running app re-reads it.
static inline NSString *APLChangedNotificationName(void) {
    static NSString *name;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        name = [APLPreferencesDomain() stringByAppendingString:@"/changed"];
    });
    return name;
}

/// Seek the value a settings row owns: the pane's own key names.
static inline NSString *APLKeyForEnabled(void) { return @"enabled"; }
static inline NSString *APLKeyForLockDelay(void) { return @"backgroundLockDelay"; }
static inline NSString *APLKeyForLockOnDeviceLock(void) { return @"lockOnDeviceLock"; }
static inline NSString *APLKeyForBundle(NSString *bundleID) {
    return [@"protected." stringByAppendingString:bundleID.length ? bundleID : @""];
}
static inline NSString *APLProtectedPrefix(void) { return @"protected."; }

/// The bundle ids a settings domain marks as protected, from the file's own
/// `protected.<bundle id>` keys.
static inline NSArray<NSString *> *APLProtectedBundleIDsInDomain(NSDictionary *domain) {
    NSMutableArray<NSString *> *bundleIDs = [NSMutableArray array];
    if (![domain isKindOfClass:[NSDictionary class]]) {
        return bundleIDs;
    }
    for (id key in domain) {
        if (![key isKindOfClass:[NSString class]] || ![key hasPrefix:APLProtectedPrefix()]) {
            continue;
        }
        id value = domain[key];
        if (![value respondsToSelector:@selector(boolValue)] || ![value boolValue]) {
            continue;
        }
        [bundleIDs addObject:[key substringFromIndex:APLProtectedPrefix().length]];
    }
    return bundleIDs;
}

/// The lock screen asks SpringBoard for Face ID here: the state of the
/// request name carries the request's token.
static inline NSString *APLAuthRequestName(NSString *bundleID) {
    return [NSString stringWithFormat:@"%@/auth/request/%@", APLPreferencesDomain(), bundleID];
}

/// SpringBoard answers here: the state carries `token << 1 | granted`.
static inline NSString *APLAuthResultName(NSString *bundleID) {
    return [NSString stringWithFormat:@"%@/auth/result/%@", APLPreferencesDomain(), bundleID];
}

/// SpringBoard's auth service publishes 1 here once it is listening, so a lock
/// screen can tell "not ready" from "Face ID failed".
static inline NSString *APLAuthServiceName(void) {
    return [APLPreferencesDomain() stringByAppendingString:@"/auth/service"];
}
