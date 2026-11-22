// SPDX-License-Identifier: MIT
//
// The Settings pane. Root.plist carries the fixed switches and section text, so
// those rows look and behave like the rest of Settings. Between them this
// controller puts the background-lock delay row, which opens a page of its own
// (Preferences' own value picker drew nothing on this iOS build), and below
// them one switch per installed app, over a search field.
// Every row stores into the package's own preferences domain and posts
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
@property (nonatomic, readonly) NSArray *appTags;
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

@interface FaceLockDelayListController : PSViewController <UITableViewDataSource, UITableViewDelegate>
@end

@implementation FaceLockDelayListController {
    UITableView *_tableView;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"后台锁定时机";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_tableView];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)APLLockDelayTitles().count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"FaceLockDelayCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
        cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        cell.textLabel.textColor = [UIColor labelColor];
    }
    NSArray<NSNumber *> *values = APLLockDelayValues();
    NSInteger current = APLIntegerPreference(APLKeyForLockDelay(), 0);
    cell.textLabel.text = APLLockDelayTitles()[indexPath.row];
    BOOL selected = indexPath.row < (NSInteger)values.count && values[indexPath.row].integerValue == current;
    cell.accessoryType = selected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSArray<NSNumber *> *values = APLLockDelayValues();
    if (indexPath.row < (NSInteger)values.count) {
        APLSetIntegerPreference(APLKeyForLockDelay(), values[indexPath.row].integerValue);
    }
    [tableView reloadData];
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

- (NSArray *)specifiers {
    if (_specifiers == nil) {
        NSMutableArray *specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];

        PSSpecifier *delay = [PSSpecifier preferenceSpecifierNamed:@"后台锁定时机"
                                                            target:self
                                                               set:nil
                                                               get:nil
                                                            detail:[FaceLockDelayListController class]
                                                              cell:PSLinkCell
                                                              edit:nil];
        NSUInteger insertAt = specifiers.count;
        for (NSUInteger index = 0; index < specifiers.count; index++) {
            if ([[specifiers[index] identifier] isEqualToString:@"deviceLock"]) {
                insertAt = index;
                break;
            }
        }
        [specifiers insertObject:delay atIndex:insertAt];

        [specifiers addObjectsFromArray:[self appSpecifiers]];
        _specifiers = specifiers;
    }
    return _specifiers;
}

#pragma mark - Rows

- (PSSpecifier *)switchRowNamed:(NSString *)name key:(NSString *)key {
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:name
                                                            target:self
                                                               set:@selector(setPreferenceValue:specifier:)
                                                               get:@selector(readPreferenceValue:)
                                                            detail:nil
                                                              cell:PSSwitchCell
                                                              edit:nil];
    [specifier setProperty:key forKey:@"key"];
    [specifier setProperty:APLPreferencesDomain() forKey:@"defaults"];
    [specifier setProperty:@NO forKey:@"default"];
    [specifier setProperty:APLChangedNotificationName() forKey:@"PostNotification"];
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

    for (LSApplicationProxy *app in apps) {
        NSString *bundleID = app.bundleIdentifier;
        NSString *name = app.localizedName.length ? app.localizedName : bundleID;

        PSSpecifier *specifier = [self switchRowNamed:name key:APLKeyForBundle(bundleID)];
        [specifier setProperty:bundleID forKey:@"id"];
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

/// The apps a person can see on the Home Screen: Apple's own apps and whatever
/// they installed. Internal components, which Launch Services tags `hidden`,
/// stay out.
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

        // Internal components (Input UI, User Authentication, view services)
        // carry a `hidden` tag; the apps on a Home Screen do not.
        NSArray *tags = nil;
        if ([app respondsToSelector:@selector(appTags)]) {
            tags = app.appTags;
        }
        if ([tags isKindOfClass:[NSArray class]] && [tags containsObject:@"hidden"]) {
            continue;
        }

        NSString *type = nil;
        if ([app respondsToSelector:@selector(applicationType)]) {
            type = app.applicationType;
        }
        if (type.length > 0 && ![type isEqualToString:@"User"] && ![type isEqualToString:@"System"]) {
            continue;  // Web clips and placeholders.
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
