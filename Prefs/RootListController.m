// SPDX-License-Identifier: MIT
//
// The Settings pane. Root.plist carries the fixed switches and section text, so
// those rows look and behave like the rest of Settings. Between them this
// controller puts the background-lock delay row, which opens a page of its own
// (Preferences' own value picker drew nothing on this iOS build), and below
// them one switch per installed app.
//
// Searching does not rebuild the pane's rows: it shows its own results table,
// which is what made typing stutter when the filtering ran through
// PSListController's insert-and-remove.
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

@protocol FaceLockProtectionToggling <NSObject>
- (BOOL)isProtectedBundleID:(NSString *)bundleID;
- (void)setProtection:(BOOL)protection forBundleID:(NSString *)bundleID;
@end

#pragma mark - Shared helpers

static UIImage *APLIconForBundle(NSString *bundleID) {
    SEL selector = @selector(_applicationIconImageForBundleIdentifier:format:scale:);
    if (![UIImage respondsToSelector:selector]) {
        return nil;
    }
    return [UIImage _applicationIconImageForBundleIdentifier:bundleID format:0 scale:[UIScreen mainScreen].scale];
}

static CFStringRef APLDomain(void) {
    return (__bridge CFStringRef)APLPreferencesDomain();
}

static BOOL APLBoolPreference(NSString *key, BOOL fallback) {
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key, APLDomain());
    if (value == NULL) {
        return fallback;
    }
    BOOL result = fallback;
    if (CFGetTypeID(value) == CFBooleanGetTypeID() || CFGetTypeID(value) == CFNumberGetTypeID()) {
        result = [(__bridge NSNumber *)value boolValue];
    }
    CFRelease(value);
    return result;
}

static void APLSetBoolPreference(NSString *key, BOOL value) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFTypeRef)@(value), APLDomain());
    CFPreferencesAppSynchronize(APLDomain());
    notify_post(APLChangedNotificationName().UTF8String);
}

#pragma mark - The delay's own page

/// The choices the 后台锁定时机 row offers, in seconds (-1: never).
static NSArray<NSNumber *> *APLLockDelayValues(void) {
    return @[@0, @30, @60, @300, @600, @-1];
}

static NSArray<NSString *> *APLLockDelayTitles(void) {
    return @[@"立即", @"30 秒后", @"1 分钟后", @"5 分钟后", @"10 分钟后", @"不锁定"];
}

static NSInteger APLIntegerPreference(NSString *key, NSInteger fallback) {
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key, APLDomain());
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
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFTypeRef)@(value), APLDomain());
    CFPreferencesAppSynchronize(APLDomain());
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

#pragma mark - Search results

/// Its own table, rebuilt from an in-memory list: typing never touches the
/// pane's specifiers.
@interface FaceLockSearchController : UIViewController <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating>
- (instancetype)initWithApps:(NSArray *)apps parent:(id<FaceLockProtectionToggling>)parent;
@end

@implementation FaceLockSearchController {
    UITableView *_tableView;
    NSArray *_apps;
    NSArray *_matches;
    __weak id<FaceLockProtectionToggling> _parent;
}

- (instancetype)initWithApps:(NSArray *)apps parent:(id<FaceLockProtectionToggling>)parent {
    self = [super initWithNibName:nil bundle:nil];
    if (self != nil) {
        _apps = [apps copy];
        _parent = parent;
        _matches = _apps;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.accessibilityIdentifier = @"FaceLockSearchResults";
    [self.view addSubview:_tableView];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *query = [[searchController.searchBar.text ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if (query.length == 0) {
        _matches = _apps;
    } else {
        NSMutableArray *matches = [NSMutableArray array];
        for (LSApplicationProxy *app in _apps) {
            NSString *name = [[app localizedName] lowercaseString];
            NSString *bundleID = [[app bundleIdentifier] lowercaseString] ?: @"";
            if ([(name ?: @"") containsString:query] || [bundleID containsString:query]) {
                [matches addObject:app];
            }
        }
        _matches = matches;
    }
    [_tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_matches.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"FaceLockSearchCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
        cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        cell.textLabel.textColor = [UIColor labelColor];
        UISwitch *toggle = [[UISwitch alloc] init];
        [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
    }
    LSApplicationProxy *app = _matches[indexPath.row];
    NSString *bundleID = app.bundleIdentifier;
    cell.textLabel.text = app.localizedName.length ? app.localizedName : bundleID;
    cell.imageView.image = APLIconForBundle(bundleID);
    UISwitch *toggle = (UISwitch *)cell.accessoryView;
    toggle.tag = indexPath.row;
    toggle.on = [_parent isProtectedBundleID:bundleID];
    return cell;
}

- (void)toggleChanged:(UISwitch *)sender {
    NSInteger row = sender.tag;
    if (row < 0 || row >= (NSInteger)_matches.count) {
        return;
    }
    LSApplicationProxy *app = _matches[(NSUInteger)row];
    [_parent setProtection:sender.on forBundleID:app.bundleIdentifier];
}

@end

#pragma mark - The pane

@interface FaceLockPrefsRootListController : PSListController <FaceLockProtectionToggling>
@end

@implementation FaceLockPrefsRootListController {
    NSMutableArray<PSSpecifier *> *_appSpecifiers;
    NSMutableDictionary<NSString *, PSSpecifier *> *_appSpecifiersByBundleID;
    NSMutableDictionary<NSString *, NSNumber *> * _stateHandles;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    FaceLockSearchController *results = [[FaceLockSearchController alloc] initWithApps:[self installedApps] parent:self];
    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:results];
    search.searchResultsUpdater = results;
    search.searchBar.placeholder = @"搜索 App";
    search.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
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

#pragma mark - Protection

- (BOOL)isProtectedBundleID:(NSString *)bundleID {
    return APLBoolPreference(APLKeyForBundle(bundleID), NO);
}

- (void)setProtection:(BOOL)protection forBundleID:(NSString *)bundleID {
    APLSetBoolPreference(APLKeyForBundle(bundleID), protection);
    [self publishProtectionState:protection forBundleID:bundleID];
    PSSpecifier *specifier = _appSpecifiersByBundleID[bundleID];
    if (specifier != nil) {
        [self reloadSpecifier:specifier];
    }
}

/// The settings file only reaches an app once cfprefsd flushes it; this Darwin
/// name carries the change at once, and the tweak reads it before the file.
- (void)publishProtectionState:(BOOL)protection forBundleID:(NSString *)bundleID {
    if (bundleID.length == 0) {
        return;
    }
    if (_stateHandles == nil) {
        _stateHandles = [NSMutableDictionary dictionary];
    }
    int handle = [_stateHandles[bundleID] intValue];
    if (handle == 0) {
        if (notify_register_check(APLProtectionStateName(bundleID).UTF8String, &handle) != NOTIFY_STATUS_OK) {
            return;
        }
        _stateHandles[bundleID] = @(handle);
    }
    notify_set_state(handle, protection ? 1 : 0);
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
    if (_appSpecifiersByBundleID == nil) {
        _appSpecifiersByBundleID = [NSMutableDictionary dictionary];
    }
    [_appSpecifiers removeAllObjects];
    [_appSpecifiersByBundleID removeAllObjects];

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
        UIImage *icon = APLIconForBundle(bundleID);
        if (icon != nil) {
            [specifier setProperty:icon forKey:@"iconImage"];
        }
        [specifiers addObject:specifier];
        [_appSpecifiers addObject:specifier];
        _appSpecifiersByBundleID[bundleID] = specifier;
        [self publishProtectionState:APLBoolPreference(APLKeyForBundle(bundleID), NO) forBundleID:bundleID];
    }
    return specifiers;
}

/// Rows written by Preferences itself (the switches in the list) reach the same
/// place as a toggle from the search results.
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    NSString *key = [specifier propertyForKey:@"key"];
    if ([key isKindOfClass:[NSString class]] && [key hasPrefix:APLProtectedPrefix()]) {
        NSString *bundleID = [key substringFromIndex:APLProtectedPrefix().length];
        [self publishProtectionState:[value boolValue] forBundleID:bundleID];
    }
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
        // Safari's "Web" bundle is an app container for web apps, not an icon
        // on a Home Screen, and Launch Services does not tag it `hidden`.
        if ([bundleID isEqualToString:@"com.apple.webapp"]) {
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
