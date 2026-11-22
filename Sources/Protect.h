// SPDX-License-Identifier: MIT
//
// Shared between the tweak that guards an app and the Settings pane that
// picks the apps: one preferences domain, one key per protected bundle id,
// one Darwin notification after a change.
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

/// The key a bundle id is protected under: `protected.<bundle id>`.
static inline NSString *APLKeyForBundle(NSString *bundleID) {
    return [@"protected." stringByAppendingString:bundleID.length ? bundleID : @""];
}

/// A boolean from the pane's domain, or `fallback` when the key is unset.
static inline BOOL APLReadBool(NSString *key, BOOL fallback) {
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)APLPreferencesDomain());
    if (value == NULL) {
        return fallback;
    }
    BOOL result = fallback;
    CFTypeID type = CFGetTypeID(value);
    if (type == CFBooleanGetTypeID()) {
        result = CFBooleanGetValue((CFBooleanRef)value);
    } else if (type == CFNumberGetTypeID()) {
        int number = 0;
        if (CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &number)) {
            result = number != 0;
        }
    }
    CFRelease(value);
    return result;
}
