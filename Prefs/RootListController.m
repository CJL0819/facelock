// SPDX-License-Identifier: MIT
//
// The Settings pane. It carries the master switch, how long the app stays
// unlocked in the background (its own page, because a list built in code is
// not what PSLinkListCell draws), whether the device locking locks the app,
// and one switch per installed app (with a search field over the list).
// Each row stores its value in the package's own preferences domain and posts
// `<package id>/changed`, which is exactly what the tweak reads inside the app.

#import <Preferences/PSListController.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <notify.h>
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

#pragma mark - The delay's own page

/// The choices the 后台锁定时机 row offers, in seconds (-1: never).
static NSArray<NSNumber *> *APLLockDelayValues(void) {
    return @[@0, @30, @60, @300, @600, @-1];
}

static NSArray<NSString *> *APLLockDelayTitles(void) {
    return @[@"立即", @"30 秒后", @"1 分钟后", @"5 分钟后", @"10 分钟后", @"不锁定"];
}

static NSInteger APLIntegerPreference(NSString *key, NSInteger fallback) {
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)APLPreferencesDomain());
    if (value == NULL) {
        return fallback;
    }
    NSInteger result = fallback;
    if (CFGetTypeID(value) == CFNumberGetTypeID() || CFGetTypeID(value) == CFBooleanGetTypeID()) {
        result = [(__bridge NSNumber *)value integerValue];
    }
    CFRelease(value);
    return result;
}

static void APLSetIntegerPreference(NSString *key, NSInteger value) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFTypeRef)@(value),
                             (__bridge CFStringRef)APLPreferencesDomain());
    CFPreferencesAppSynchronize((__bridge CFStringRef)APLPreferencesDomain());
    notify_post(APLChangedNotificationName().UTF8String);
}

@interface FaceLockDelayListController : PSListController
@end

@implementation FaceLockDelayListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"后台锁定时机";
}

- (NSArray *)specifiers {
    if (_specifiers == nil) {
        NSMutableArray *specifiers = [NSMutableArray array];
        for (NSString *title in APLLockDelayTitles()) {
            PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:title
                                                                    target:self
                                                                       set:nil
                                                                       get:nil
                                                                    detail:nil
                                                                      cell:PSListItemCell
                                                                      edit:nil];
            [specifiers addObject:specifier];
        }
        _specifiers = specifiers;
    }
    return _specifiers;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    NSArray<NSNumber *> *values = APLLockDelayValues();
    NSInteger current = APLIntegerPreference(APLKeyForLockDelay(), 0);
    BOOL selected = indexPath.row < (NSInteger)values.count && values[indexPath.row].integerValue == current;
    cell.accessoryType = selected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    cell.tintColor = [UIColor colorWithRed:0.0 green:0.478 blue:1.0 alpha:1.0];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSArray<NSNumber *> *values = APLLockDelayValues();
    if (indexPath.row < (NSInteger)values.count) {
        APLSetIntegerPreference(APLKeyForLockDelay(), values[indexPath.row].integerValue);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self.navigationController popViewControllerAnimated:YES];
    });
}

@end

#pragma mark - The pane

@interface FaceLockPrefsRootListController : PSListController <UISearchResultsUpdating>
@end

@implementation FaceLockPrefsRootListController {
    NSMutableArray<PSSpecifier *> *_appSpecifiers;
    NSString *_appliedQuery;
    NSUInteger _searchGeneration;
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

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // The delay page may have changed the value behind this row: show it.
    PSSpecifier *delay = [self specifierForID:@"lockDelay"];
    if (delay != nil) {
        delay.name = [self delayRowName];
        [self reloadSpecifier:delay];
    }
}

/// The row's label carries the choice, so the pane shows it without opening
/// the page again.
- (NSString *)delayRowName {
    NSInteger current = APLIntegerPreference(APLKeyForLockDelay(), 0);
    NSUInteger index = [APLLockDelayValues() indexOfObject:@(current)];
    NSString *title = index == NSNotFound ? @"立即" : APLLockDelayTitles()[index];
    return [NSString stringWithFormat:@"后台锁定时机 · %@", title];
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

    PSSpecifier *delay = [PSSpecifier preferenceSpecifierNamed:[self delayRowName]
                                                        target:self
                                                           set:nil
                                                           get:@selector(delayDescription:)
                                                        detail:[FaceLockDelayListController class]
                                                          cell:PSLinkCell
                                                          edit:nil];
    delay.identifier = @"lockDelay";
    [specifiers addObject:delay];

    PSSpecifier *deviceLock = [self valueRowNamed:@"设备锁屏时锁定" key:APLKeyForLockOnDeviceLock() domain:domain notification:notification];
    [deviceLock setProperty:@YES forKey:@"default"];
    [specifiers addObject:deviceLock];

    [specifiers addObjectsFromArray:[self appSpecifiers]];
    return specifiers;
}

/// The subtitle a link row shows for the delay page.
- (id)delayDescription:(PSSpecifier *)specifier {
    NSInteger current = APLIntegerPreference(APLKeyForLockDelay(), 0);
    NSUInteger index = [APLLockDelayValues() indexOfObject:@(current)];
    return index == NSNotFound ? @"立即" : APLLockDelayTitles()[index];
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
    NSString *query = [[searchController.searchBar.text ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if ([query isEqualToString:_appliedQuery ?: @""]) {
        return;
    }
    // Filtering rebuilds rows; one keystroke at a time made typing feel stuck,
    // so wait for the run of keystrokes to settle.
    NSUInteger generation = ++_searchGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf->_searchGeneration != generation) {
            return;
        }
        strongSelf->_appliedQuery = query;
        [strongSelf applyQuery:query];
    });
}

- (void)applyQuery:(NSString *)query {
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

/// The apps a person installed: App Store, TrollStore and sideloaded ones.
/// System apps are left out, as asked.
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
        if ([app respondsToSelector:@selector(applicationType)] && ![app.applicationType isEqualToString:@"User"]) {
            continue;  // System apps stay out of the list.
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
