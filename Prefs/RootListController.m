// SPDX-License-Identifier: MIT
//
// The Settings pane. Root.plist carries the master switch; the rows below it
// are one switch per installed app, built here from Launch Services. Each row
// stores `protected.<bundle id>` in the package's own preferences domain and
// posts `<package id>/changed`, which is exactly what the tweak reads inside
// the app.

#import <Preferences/PSListController.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>

#import "Protect.h"

// Launch Services is private: declare only what is sent to it.
@interface LSApplicationProxy : NSObject
@property (nonatomic, readonly) NSString *bundleIdentifier;
@property (nonatomic, readonly) NSString *localizedName;
@property (nonatomic, readonly) NSString *applicationType;
@property (nonatomic, readonly, getter=isHidden) BOOL hidden;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allInstalledApplications;
@end

@interface UIImage (APLAppIcon)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleID format:(int)format scale:(CGFloat)scale;
@end

@interface FaceLockPrefsRootListController : PSListController
@end

@implementation FaceLockPrefsRootListController

- (NSArray *)specifiers {
    if (_specifiers == nil) {
        _specifiers = [self buildSpecifiers];
    }
    return _specifiers;
}

- (NSMutableArray *)buildSpecifiers {
    NSMutableArray *specifiers = [NSMutableArray array];
    NSString *domain = APLPreferencesDomain();
    NSString *notification = APLChangedNotificationName();

    PSSpecifier *intro = [PSSpecifier groupSpecifierWithName:@"面容锁"];
    [intro setProperty:@"打开受保护的 App 时需要面容 ID 验证，验证不通过就无法继续使用。App 退到后台后会重新上锁。"
                forKey:@"footerText"];
    [specifiers addObject:intro];

    PSSpecifier *master = [PSSpecifier preferenceSpecifierNamed:@"启用保护"
                                                         target:self
                                                            set:@selector(setPreferenceValue:specifier:)
                                                            get:@selector(readPreferenceValue:)
                                                         detail:nil
                                                           cell:PSSwitchCell
                                                           edit:nil];
    [master setProperty:@"enabled" forKey:@"key"];
    [master setProperty:domain forKey:@"defaults"];
    [master setProperty:@YES forKey:@"default"];
    [master setProperty:notification forKey:@"PostNotification"];
    [specifiers addObject:master];

    [specifiers addObjectsFromArray:[self appSpecifiers]];
    return specifiers;
}

#pragma mark - Rows

- (NSArray *)appSpecifiers {
    NSMutableArray *specifiers = [NSMutableArray array];

    PSSpecifier *header = [PSSpecifier groupSpecifierWithName:@"已保护的 App"];
    NSArray *apps = [self installedApps];
    [header setProperty:(apps.count > 0
                         ? [NSString stringWithFormat:@"共 %lu 个 App。打开受保护的 App 时需要面容 ID 验证，验证不通过就无法继续使用。", (unsigned long)apps.count]
                         : @"读取不到已安装的 App 列表，请重新打开设置页。")
                 forKey:@"footerText"];
    [specifiers addObject:header];

    NSString *domain = APLPreferencesDomain();
    NSString *notification = APLChangedNotificationName();

    for (LSApplicationProxy *app in apps) {
        NSString *bundleID = app.bundleIdentifier;
        NSString *name = app.localizedName.length ? app.localizedName : bundleID;

        PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:name
                                                               target:self
                                                                  set:@selector(setPreferenceValue:specifier:)
                                                                  get:@selector(readPreferenceValue:)
                                                               detail:nil
                                                                 cell:PSSwitchCell
                                                                 edit:nil];
        [specifier setProperty:bundleID forKey:@"id"];
        [specifier setProperty:APLKeyForBundle(bundleID) forKey:@"key"];
        [specifier setProperty:domain forKey:@"defaults"];
        [specifier setProperty:@NO forKey:@"default"];
        [specifier setProperty:notification forKey:@"PostNotification"];
        UIImage *icon = [self iconForBundleID:bundleID];
        if (icon != nil) {
            [specifier setProperty:icon forKey:@"iconImage"];
        }
        [specifiers addObject:specifier];
    }
    return specifiers;
}

- (UIImage *)iconForBundleID:(NSString *)bundleID {
    SEL selector = @selector(_applicationIconImageForBundleIdentifier:format:scale:);
    if (![UIImage respondsToSelector:selector]) {
        return nil;
    }
    return [UIImage _applicationIconImageForBundleIdentifier:bundleID format:0 scale:[UIScreen mainScreen].scale];
}

#pragma mark - Launch Services

- (id)workspace {
    static id workspace;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
        if (workspaceClass == Nil) {
            static const char *paths[] = {
                "/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",
                "/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices",
                "/System/Library/PrivateFrameworks/LaunchServices.framework/LaunchServices",
                "/System/Library/Frameworks/CoreServices.framework/CoreServices",
            };
            for (size_t index = 0; index < sizeof(paths) / sizeof(paths[0]); index++) {
                if (dlopen(paths[index], RTLD_LAZY) == NULL) {
                    continue;
                }
                workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
                if (workspaceClass != Nil) {
                    break;
                }
            }
        }
        if (workspaceClass != Nil) {
            workspace = [(id)workspaceClass defaultWorkspace];
        }
    });
    return workspace;
}

- (NSArray *)installedApps {
    id workspace = [self workspace];
    if (workspace == nil || ![workspace respondsToSelector:@selector(allInstalledApplications)]) {
        return @[];
    }
    NSArray *all = [workspace allInstalledApplications];
    if (![all isKindOfClass:[NSArray class]]) {
        return @[];
    }

    NSMutableArray *apps = [NSMutableArray array];
    for (id candidate in all) {
        if (![candidate isKindOfClass:NSClassFromString(@"LSApplicationProxy")]) {
            continue;
        }
        LSApplicationProxy *app = (LSApplicationProxy *)candidate;
        NSString *bundleID = app.bundleIdentifier;
        if (bundleID.length == 0 || [bundleID isEqualToString:@"com.apple.springboard"]) {
            continue;
        }
        if ([app respondsToSelector:@selector(applicationType)]) {
            NSString *type = app.applicationType;
            if (type.length > 0 && ![type isEqualToString:@"User"] && ![type isEqualToString:@"System"]) {
                continue;  // Web apps, placeholders and the like.
            }
        }
        if ([app respondsToSelector:@selector(isHidden)] && app.isHidden) {
            continue;
        }
        [apps addObject:app];
    }

    [apps sortUsingComparator:^NSComparisonResult(LSApplicationProxy *left, LSApplicationProxy *right) {
        NSString *leftName = left.localizedName.length ? left.localizedName : left.bundleIdentifier;
        NSString *rightName = right.localizedName.length ? right.localizedName : right.bundleIdentifier;
        return [leftName caseInsensitiveCompare:rightName];
    }];
    return apps;
}

@end
