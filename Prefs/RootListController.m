// SPDX-License-Identifier: MIT
//
// The Settings pane. It carries the master switch, how long the app stays
// unlocked in the background, whether the device locking locks the app, and
// one switch per installed app (with a search field over the list). Each row
// stores its value in the package's own preferences domain and posts
// `<package id>/changed`, which is exactly what the tweak reads inside the app.

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

@interface FaceLockPrefsRootListController : PSListController <UISearchResultsUpdating>
@end

@implementation FaceLockPrefsRootListController {
    NSMutableArray<PSSpecifier *> *_appSpecifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = @"搜索 App";
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
}

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
    [intro setProperty:@"打开受保护的 App 时需要面容 ID 验证，验证不通过就无法继续使用。" forKey:@"footerText"];
    [specifiers addObject:intro];

    PSSpecifier *master = [self valueRowNamed:@"启用保护" key:APLKeyForEnabled() domain:domain notification:notification];
    [master setProperty:@YES forKey:@"default"];
    [specifiers addObject:master];

    PSSpecifier *timing = [PSSpecifier groupSpecifierWithName:@"锁定时机"];
    [timing setProperty:@"每次打开 App 都会验证一次。退到后台超过设定时间再回来、或设备锁屏时，也会重新验证。"
                 forKey:@"footerText"];
    [specifiers addObject:timing];

    PSSpecifier *delay = [PSSpecifier preferenceSpecifierNamed:@"后台锁定时机"
                                                        target:self
                                                           set:@selector(setPreferenceValue:specifier:)
                                                           get:@selector(readPreferenceValue:)
                                                        detail:nil
                                                          cell:PSLinkListCell
                                                          edit:nil];
    [delay setProperty:APLKeyForLockDelay() forKey:@"key"];
    [delay setProperty:domain forKey:@"defaults"];
    [delay setProperty:@0 forKey:@"default"];
    [delay setProperty:@[@-1, @0, @30, @60, @300, @600] forKey:@"values"];
    [delay setProperty:@[@"不锁定", @"立即", @"30 秒后", @"1 分钟后", @"5 分钟后", @"10 分钟后"] forKey:@"titles"];
    [delay setProperty:notification forKey:@"PostNotification"];
    [specifiers addObject:delay];

    PSSpecifier *deviceLock = [self valueRowNamed:@"设备锁屏时锁定" key:APLKeyForLockOnDeviceLock() domain:domain notification:notification];
    [deviceLock setProperty:@YES forKey:@"default"];
    [specifiers addObject:deviceLock];

    [specifiers addObjectsFromArray:[self appSpecifiers]];
    return specifiers;
}

#pragma mark - Rows

- (PSSpecifier *)valueRowNamed:(NSString *)name key:(NSString *)key domain:(NSString *)domain notification:(NSString *)notification {
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:name
                                                            target:self
                                                               set:@selector(setPreferenceValue:specifier:)
                                                               get:@selector(readPreferenceValue:)
                                                            detail:nil
                                                              cell:PSSwitchCell
                                                              edit:nil];
    [specifier setProperty:key forKey:@"key"];
    [specifier setProperty:domain forKey:@"defaults"];
    [specifier setProperty:notification forKey:@"PostNotification"];
    return specifier;
}

- (NSArray *)appSpecifiers {
    NSMutableArray *specifiers = [NSMutableArray array];
    if (_appSpecifiers == nil) {
        _appSpecifiers = [NSMutableArray array];
    }
    [_appSpecifiers removeAllObjects];

    PSSpecifier *header = [PSSpecifier groupSpecifierWithName:@"已保护的 App"];
    NSArray *apps = [self installedApps];
    [header setProperty:(apps.count > 0
                         ? [NSString stringWithFormat:@"共 %lu 个 App，打开开关即受面容 ID 保护。", (unsigned long)apps.count]
                         : @"读取不到已安装的 App 列表，请重新打开设置页。")
                 forKey:@"footerText"];
    [specifiers addObject:header];

    NSString *domain = APLPreferencesDomain();
    NSString *notification = APLChangedNotificationName();

    for (LSApplicationProxy *app in apps) {
        NSString *bundleID = app.bundleIdentifier;
        NSString *name = app.localizedName.length ? app.localizedName : bundleID;

        PSSpecifier *specifier = [self valueRowNamed:name key:APLKeyForBundle(bundleID) domain:domain notification:notification];
        [specifier setProperty:bundleID forKey:@"id"];
        [specifier setProperty:@NO forKey:@"default"];
        UIImage *icon = [self iconForBundleID:bundleID];
        if (icon != nil) {
            [specifier setProperty:icon forKey:@"iconImage"];
        }
        [specifiers addObject:specifier];
        [_appSpecifiers addObject:specifier];
    }
    return specifiers;
}

#pragma mark - Search

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *query = [[[searchController.searchBar.text ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString] copy];
    NSArray *visible = [[self specifiers] copy];
    for (PSSpecifier *specifier in _appSpecifiers) {
        if ([visible containsObject:specifier]) {
            [self removeSpecifier:specifier animated:NO];
        }
    }
    NSInteger index = (NSInteger)[[self specifiers] count];
    for (PSSpecifier *specifier in _appSpecifiers) {
        NSString *name = [[specifier name] lowercaseString];
        NSString *bundleID = [[specifier propertyForKey:@"id"] lowercaseString] ?: @"";
        BOOL matches = query.length == 0 || [name containsString:query] || [bundleID containsString:query];
        if (!matches) {
            continue;
        }
        [self insertSpecifier:specifier atIndex:index animated:NO];
        index++;
    }
}

#pragma mark - Icons

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
