// SPDX-License-Identifier: MIT
//
// The tweak loads into every app process and into SpringBoard (the package's
// filter names the UIApplication class, which both have).
//
// In an app it reads the package's preferences domain: if this app is
// protected, a window above the app's own holds it until Face ID has passed.
// The Face ID itself runs in SpringBoard: an app process has no
// NSFaceIDUsageDescription, and asking LocalAuthentication from one is a TCC
// violation that kills the app, while SpringBoard's entitlements allow it.
// The passcode prompt stays in the app, where LocalAuthentication is safe.

#import <CoreFoundation/CoreFoundation.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <stdlib.h>
#import <substrate.h>

#import "ApelinBootstrap.h"
#import "Protect.h"

static os_log_t TweakLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create(APELIN_PACKAGE_ID, "tweak");
    });
    return log;
}

#pragma mark - Talking to SpringBoard's auth service

static BOOL APLAuthServiceReady(void) {
    int handle = 0;
    if (notify_register_check(APLAuthServiceName().UTF8String, &handle) != NOTIFY_STATUS_OK) {
        return NO;
    }
    uint64_t state = 0;
    notify_get_state(handle, &state);
    notify_cancel(handle);
    return state == 1;
}

#pragma mark - The lock screen

// Launch Services is private: declare only what is sent to it, so the class is
// reached by name at run time.
@interface APLLaunchServicesProxy : NSObject
+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
- (NSString *)localizedName;
- (NSString *)bundleIdentifier;
@end

@interface APLLaunchServicesWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allInstalledApplications;
@end

// The window that sits above the app until Face ID has passed.
@interface APLLockViewController : UIViewController
@property (nonatomic, copy) NSString *appName;
@property (nonatomic, copy) void (^onUnlocked)(void);
- (void)authenticate;
- (void)resetAutoAttempts;
- (void)setStatusText:(NSString *)text;
@end

static NSString *sBundleID;
static NSString *sAppName;
static BOOL sEnabled;
static BOOL sProtected;
static BOOL sLocked;
static BOOL sPrompted;
static BOOL sPrepared;
static BOOL sLockOnDeviceLock;
static NSInteger sLockDelay;
static NSDate *sBackgroundDate;
static UIWindow *sLockWindow;
static APLLockViewController *sLockController;

static UIColor *APLAccentColor(void) {
    return [UIColor colorWithRed:0.0 green:0.478 blue:1.0 alpha:1.0];
}

@implementation APLLockViewController {
    UILabel *_statusLabel;
    UIButton *_unlockButton;
    UIButton *_passcodeButton;
    LAContext *_context;
    BOOL _authenticating;
    BOOL _passcodeInFlight;
    BOOL _didPrompt;
    NSUInteger _autoAttempts;
    BOOL _requestWasAutomatic;
    uint32_t _requestToken;
    int _resultHandle;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor blackColor];

    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];
    blur.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:blur];

    UIImageView *iconView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"faceid"]];
    iconView.tintColor = [UIColor whiteColor];
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    [iconView.widthAnchor constraintEqualToConstant:72.0].active = YES;
    [iconView.heightAnchor constraintEqualToConstant:72.0].active = YES;

    UILabel *titleLabel = [UILabel new];
    titleLabel.text = @"已锁定";
    titleLabel.font = [UIFont systemFontOfSize:28.0 weight:UIFontWeightBold];
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.textAlignment = NSTextAlignmentCenter;

    UILabel *nameLabel = [UILabel new];
    nameLabel.text = self.appName.length ? self.appName : @"此 App";
    nameLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightMedium];
    nameLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.7];
    nameLabel.textAlignment = NSTextAlignmentCenter;
    nameLabel.numberOfLines = 2;

    UILabel *hintLabel = [UILabel new];
    hintLabel.text = @"使用面容 ID 验证后才能继续使用";
    hintLabel.font = [UIFont systemFontOfSize:15.0];
    hintLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    hintLabel.textAlignment = NSTextAlignmentCenter;
    hintLabel.numberOfLines = 2;

    _unlockButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_unlockButton setTitle:@"使用面容 ID 解锁" forState:UIControlStateNormal];
    [_unlockButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _unlockButton.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    _unlockButton.backgroundColor = APLAccentColor();
    _unlockButton.layer.cornerRadius = 23.0;
    _unlockButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_unlockButton.widthAnchor constraintEqualToConstant:236.0].active = YES;
    [_unlockButton.heightAnchor constraintEqualToConstant:46.0].active = YES;
    [_unlockButton addTarget:self action:@selector(unlockTapped:) forControlEvents:UIControlEventTouchUpInside];

    _passcodeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_passcodeButton setTitle:@"使用密码" forState:UIControlStateNormal];
    [_passcodeButton setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.75] forState:UIControlStateNormal];
    _passcodeButton.titleLabel.font = [UIFont systemFontOfSize:15.0];
    _passcodeButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_passcodeButton.heightAnchor constraintEqualToConstant:32.0].active = YES;
    [_passcodeButton addTarget:self action:@selector(passcodeTapped:) forControlEvents:UIControlEventTouchUpInside];

    _statusLabel = [UILabel new];
    _statusLabel.font = [UIFont systemFontOfSize:13.0];
    _statusLabel.textColor = [UIColor colorWithRed:1.0 green:0.42 blue:0.42 alpha:1.0];
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.numberOfLines = 2;
    _statusLabel.text = @"";
    // Always in the layout, with room for two lines: a status that comes and
    // goes would move everything above it on the lock screen.
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_statusLabel.heightAnchor constraintEqualToConstant:38.0].active = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[iconView, titleLabel, nameLabel, hintLabel, _unlockButton, _passcodeButton, _statusLabel]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 12.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [stack setCustomSpacing:24.0 afterView:hintLabel];
    [stack setCustomSpacing:4.0 afterView:_unlockButton];
    [stack setCustomSpacing:12.0 afterView:_passcodeButton];
    [self.view addSubview:stack];

    UILayoutGuide *margins = self.view.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [blur.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [blur.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [blur.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [blur.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:margins.leadingAnchor],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:margins.trailingAnchor],
        [stack.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
    ]];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (_didPrompt) {
        return;
    }
    _didPrompt = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self authenticate];
    });
}

- (void)unlockTapped:(id)sender {
    os_log(TweakLog(), "unlock button tapped");
    [self requestFaceIDAutomatic:NO];
}

- (void)passcodeTapped:(id)sender {
    os_log(TweakLog(), "passcode button tapped");
    // A Face ID request nobody answered must not keep the passcode out.
    _authenticating = NO;
    [self evaluatePasscode];
}

- (void)setStatusText:(NSString *)text {
    _statusLabel.text = text ?: @"";
}

#pragma mark Face ID, asked of SpringBoard

- (void)resetAutoAttempts {
    _autoAttempts = 0;
}

// Three automatic tries per lock; after that the buttons are the way in, and
// nothing pops up on its own.
- (void)authenticate {
    if (_autoAttempts >= 3) {
        os_log(TweakLog(), "three automatic Face ID tries spent, waiting for a tap");
        return;
    }
    [self requestFaceIDAutomatic:YES];
}

- (void)requestFaceIDAutomatic:(BOOL)automatic {
    if (_authenticating) {
        return;
    }
    _requestWasAutomatic = automatic;
    if (!APLAuthServiceReady()) {
        os_log(TweakLog(), "auth service not ready");
        [self setStatusText:@"面容 ID 服务未就绪：请先重新启动桌面（respring），或用密码解锁"];
        return;
    }
    _authenticating = YES;
    [self setStatusText:nil];

    uint32_t token = ((uint32_t)arc4random() | 1u);
    _requestToken = token;

    NSString *requestName = APLAuthRequestName(sBundleID ?: @"");
    int requestHandle = 0;
    if (notify_register_check(requestName.UTF8String, &requestHandle) != NOTIFY_STATUS_OK) {
        _authenticating = NO;
        [self setStatusText:@"无法请求面容 ID，请重试"];
        return;
    }
    notify_set_state(requestHandle, (uint64_t)token);
    notify_post(requestName.UTF8String);

    // The service may have only just been told about this app; ask again once
    // if nothing comes back.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self->_authenticating && self->_requestToken == token) {
            notify_post(requestName.UTF8String);
        }
    });
    notify_cancel(requestHandle);
    os_log(TweakLog(), "asked for Face ID, token %u", token);

    if (_resultHandle != 0) {
        notify_cancel(_resultHandle);
        _resultHandle = 0;
    }
    NSString *resultName = APLAuthResultName(sBundleID ?: @"");
    notify_register_dispatch(resultName.UTF8String, &_resultHandle, dispatch_get_main_queue(), ^(int stateHandle) {
        uint64_t state = 0;
        if (notify_get_state(stateHandle, &state) != NOTIFY_STATUS_OK) {
            return;
        }
        if ((uint32_t)(state >> 1) != token) {
            return;  // An older request's answer.
        }
        notify_cancel(stateHandle);
        self->_resultHandle = 0;
        if (!self->_authenticating) {
            return;
        }
        self->_authenticating = NO;
        BOOL granted = (state & 1) != 0;
        os_log(TweakLog(), "Face ID answer granted=%d automatic=%d", (int)granted, (int)self->_requestWasAutomatic);
        if (granted) {
            self->_autoAttempts = 0;
            [self setStatusText:nil];
            if (self.onUnlocked) {
                self.onUnlocked();
            }
        } else if (self->_requestWasAutomatic) {
            // A failed automatic try hands over quietly to the user.
            self->_autoAttempts += 1;
            [self setStatusText:nil];
        } else {
            [self setStatusText:@"面容 ID 未通过，可重试或使用密码"];
        }
    });

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil || !strongSelf->_authenticating || strongSelf->_requestToken != token) {
            return;
        }
        strongSelf->_authenticating = NO;
        if (strongSelf->_requestWasAutomatic) {
            strongSelf->_autoAttempts += 1;
            [strongSelf setStatusText:nil];
        } else {
            [strongSelf setStatusText:@"面容 ID 没有回应，请重试"];
        }
    });
}

#pragma mark Passcode, asked here

// Safe in an app process: this policy asks for the passcode, not for Face ID.
- (void)evaluatePasscode {
    if (_passcodeInFlight) {
        return;
    }
    _passcodeInFlight = YES;
    _authenticating = NO;  // the passcode does not wait for a Face ID answer
    [self setStatusText:nil];

    LAContext *context = [[LAContext alloc] init];
    _context = context;
    context.localizedCancelTitle = @"取消";

    NSError *availability = nil;
    if (![context canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:&availability]) {
        _passcodeInFlight = NO;
        _context = nil;
        [self setStatusText:@"密码验证不可用"];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [context evaluatePolicy:LAPolicyDeviceOwnerAuthentication
            localizedReason:[NSString stringWithFormat:@"解锁“%@”", self.appName.length ? self.appName : @"此 App"]
                      reply:^(BOOL success, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            strongSelf->_passcodeInFlight = NO;
            strongSelf->_context = nil;
            os_log(TweakLog(), "passcode success=%d error=%{public}s", (int)success, error.localizedDescription.UTF8String ?: "(none)");
            if (success) {
                [strongSelf setStatusText:nil];
                if (strongSelf.onUnlocked) {
                    strongSelf.onUnlocked();
                }
            } else if (error.code != LAErrorUserCancel && error.code != LAErrorSystemCancel && error.code != LAErrorAppCancel) {
                [strongSelf setStatusText:[NSString stringWithFormat:@"未通过验证：%@",
                                           error.localizedDescription.length ? error.localizedDescription : @"请重试"]];
            }
        });
    }];
}

@end

#pragma mark - Showing and hiding the lock

static UIWindowScene *APLForegroundWindowScene(void) {
    UIApplication *application = [UIApplication sharedApplication];
    UIWindowScene *fallback = nil;
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.activationState == UISceneActivationStateForegroundActive) {
            return windowScene;
        }
        if (fallback == nil) {
            fallback = windowScene;
        }
    }
    return fallback;
}

static void APLAttachLockWindow(UIWindowScene *scene) {
    if (sLockWindow == nil || scene == nil) {
        return;
    }
    if (sLockWindow.windowScene != scene) {
        sLockWindow.windowScene = scene;
    }
    sLockWindow.frame = scene.coordinateSpace.bounds;
    sLockWindow.hidden = NO;
}

// A window made after iOS 13 shows only once it belongs to a scene; the app's
// scene may not be connected yet when this runs at launch.
static void APLPlaceLockWindow(void) {
    APLAttachLockWindow(APLForegroundWindowScene());
}

static void APLHideLockWindow(void) {
    if (sLockWindow == nil) {
        return;
    }
    sLockWindow.alpha = 1.0;
    sLockWindow.hidden = YES;
    [sLockController setStatusText:nil];
}

static void APLShowLock(void) {
    if (!sLocked) {
        return;
    }
    if (sLockWindow == nil) {
        sLockWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        sLockWindow.windowLevel = UIWindowLevelAlert + 1000.0;
        sLockWindow.backgroundColor = [UIColor blackColor];

        APLLockViewController *controller = [[APLLockViewController alloc] init];
        controller.appName = sAppName;
        controller.onUnlocked = ^{
            sLocked = NO;
            sPrompted = NO;
            os_log(TweakLog(), "unlocked %{public}s", sBundleID.UTF8String ?: "");
            if (sLockWindow == nil) {
                return;
            }
            [UIView animateWithDuration:0.2
                             animations:^{
                sLockWindow.alpha = 0.0;
            } completion:^(BOOL __unused finished) {
                sLockWindow.hidden = YES;
                sLockWindow.alpha = 1.0;
            }];
        };
        sLockWindow.rootViewController = controller;
        sLockController = controller;
    }
    sLockWindow.alpha = 1.0;
    sLockWindow.hidden = NO;
    sLockWindow.windowLevel = UIWindowLevelAlert + 1000.0;
    APLPlaceLockWindow();
    [sLockWindow makeKeyAndVisible];
    if (sLockWindow.windowScene == nil) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            APLPlaceLockWindow();
        });
    }
}

// Engage the lock. A new lock also gives Face ID its three automatic tries
// again.
static void APLLockApp(void) {
    sLocked = YES;
    sPrompted = NO;
    [sLockController resetAutoAttempts];
    APLShowLock();
}

static void APLPromptIfNeeded(void) {
    if (!sLocked || sPrompted || sLockController == nil) {
        return;
    }
    sPrompted = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (sLocked && sLockController != nil) {
            [sLockController authenticate];
        }
    });
}

#pragma mark - Reading the settings

static NSString *APLHostDisplayName(void) {
    NSBundle *bundle = [NSBundle mainBundle];
    NSDictionary *info = bundle.localizedInfoDictionary ?: bundle.infoDictionary;
    NSString *name = info[@"CFBundleDisplayName"];
    if (name.length == 0) {
        name = info[@"CFBundleName"];
    }
    if (name.length == 0) {
        // Some apps keep their display name in a localized InfoPlist.strings
        // only; Launch Services has it either way.
        Class proxyClass = NSClassFromString(@"LSApplicationProxy");
        if (proxyClass == Nil) {
            dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
            proxyClass = NSClassFromString(@"LSApplicationProxy");
        }
        if (proxyClass != Nil) {
            id proxy = [(id)proxyClass applicationProxyForIdentifier:bundle.bundleIdentifier];
            NSString *localized = [proxy localizedName];
            if (localized.length > 0) {
                return localized;
            }
        }
    }
    if (name.length == 0) {
        name = bundle.bundleIdentifier;
    }
    return name.length ? name : @"此 App";
}

// cfprefsd keeps this device's domains in the bootstrap's own
// ~/Library/Preferences, so that file can be read without a cfprefsd round
// trip. On the launch path the round trip is what hangs a sandboxed app, and
// from inside a sandboxed app a cfprefsd read of the domain comes back empty.
static NSDictionary *APLReadSettingsFile(void) {
    NSString *name = [APLPreferencesDomain() stringByAppendingString:@".plist"];
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    NSString *bootstrapPath = ApelinBootstrapPath([@"/var/mobile/Library/Preferences/" stringByAppendingString:name]);
    if (bootstrapPath.length > 0) {
        [candidates addObject:bootstrapPath];
    }
    [candidates addObject:[@"/var/mobile/Library/Preferences/" stringByAppendingString:name]];

    for (NSUInteger index = 0; index < candidates.count; index++) {
        NSDictionary *domain = [NSDictionary dictionaryWithContentsOfFile:candidates[index]];
        if ([domain isKindOfClass:[NSDictionary class]]) {
            return domain;
        }
    }
    return nil;
}

static BOOL APLBoolInDomain(NSDictionary *domain, NSString *key, BOOL fallback) {
    id value = domain[key];
    if ([value isKindOfClass:[NSNumber class]] || [value isKindOfClass:[NSString class]]) {
        return [value boolValue];
    }
    return fallback;
}

static NSInteger APLIntegerInDomain(NSDictionary *domain, NSString *key, NSInteger fallback) {
    id value = domain[key];
    if ([value isKindOfClass:[NSNumber class]] || [value isKindOfClass:[NSString class]]) {
        return [value integerValue];
    }
    return fallback;
}

static void APLApplyDomain(NSDictionary *domain, BOOL enabled, BOOL protected) {
    if (sBundleID.length == 0) {
        return;
    }
    BOOL wasProtected = sProtected;
    sEnabled = enabled;
    sProtected = protected;
    sLockDelay = domain != nil ? APLIntegerInDomain(domain, APLKeyForLockDelay(), 0) : 0;
    sLockOnDeviceLock = domain != nil ? APLBoolInDomain(domain, APLKeyForLockOnDeviceLock(), YES) : YES;
    os_log(TweakLog(), "state enabled=%d protected=%d delay=%ld deviceLock=%d",
           (int)sEnabled, (int)sProtected, (long)sLockDelay, (int)sLockOnDeviceLock);

    if (!(sEnabled && sProtected)) {
        if (sLocked) {
            sLocked = NO;
            sPrompted = NO;
            APLHideLockWindow();
        }
        return;
    }
    if (!wasProtected) {
        // Newly protected, or the launch read: lock before anything is usable.
        APLLockApp();
        APLPromptIfNeeded();
        return;
    }
    // Already unlocked by the user: a settings re-read must not lock it again.
    if (sLocked && sLockWindow.hidden) {
        APLShowLock();
    }
}

// The pane sets this the instant a switch goes on, which is faster than the
// settings file cfprefsd has not flushed yet.
static BOOL APLNotifySaysProtected(NSString *bundleID) {
    int handle = 0;
    if (notify_register_check(APLProtectionStateName(bundleID).UTF8String, &handle) != NOTIFY_STATUS_OK) {
        return NO;
    }
    uint64_t state = 0;
    notify_get_state(handle, &state);
    notify_cancel(handle);
    return state == 1;
}

static void APLApplyStateFromFile(void) {
    if (sBundleID.length == 0) {
        return;
    }
    NSDictionary *domain = APLReadSettingsFile();
    BOOL enabled = domain != nil ? APLBoolInDomain(domain, APLKeyForEnabled(), YES) : YES;
    BOOL protected = domain != nil ? APLBoolInDomain(domain, APLKeyForBundle(sBundleID), NO) : NO;
    if (!protected && APLNotifySaysProtected(sBundleID)) {
        os_log(TweakLog(), "protection came from the pane's signal");
        protected = YES;
    }
    APLApplyDomain(domain, enabled, protected);
}

// The pane writes through cfprefsd, which flushes the file a moment after it
// posts the notification: read once now and again after the flush.
static void APLReapplyAfterChanges(const double *delays, size_t count) {
    APLApplyStateFromFile();
    for (size_t index = 0; index < count; index++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[index] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            APLApplyStateFromFile();
        });
    }
}

static void APLInstallObservers(void) {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];

    [center addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *__unused note) {
        if (!sEnabled || !sProtected) {
            // Protection may have been switched on while this app waited in
            // the background: read the settings again before deciding.
            APLApplyStateFromFile();
        }
        if (!sEnabled || !sProtected) {
            return;
        }
        // Back from the background: lock once the chosen wait has passed.
        if (!sLocked && sBackgroundDate != nil && sLockDelay > 0) {
            NSTimeInterval away = -[sBackgroundDate timeIntervalSinceNow];
            if (away >= (NSTimeInterval)sLockDelay) {
                os_log(TweakLog(), "away %.0fs, locking", away);
                APLLockApp();
            }
        }
        sBackgroundDate = nil;
        if (!sLocked) {
            return;
        }
        APLShowLock();
        sPrompted = NO;
        APLPromptIfNeeded();
    }];

    // Leaving the app: with an immediate lock the app switcher shows the lock
    // screen rather than the app's content; otherwise leave it and time it.
    [center addObserverForName:UIApplicationDidEnterBackgroundNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *__unused note) {
        if (!sEnabled || !sProtected) {
            return;
        }
        sBackgroundDate = [NSDate date];
        if (sLockDelay == 0) {
            APLLockApp();
        }
    }];

    // The device locked (the passcode-protected data went away): lock too.
    [center addObserverForName:UIApplicationProtectedDataWillBecomeUnavailable
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *__unused note) {
        if (!sEnabled || !sProtected || !sLockOnDeviceLock) {
            return;
        }
        os_log(TweakLog(), "device locked, locking app");
        APLLockApp();
    }];

    [center addObserverForName:UISceneWillConnectNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
        // The app's scene connects before it draws: take it now, so the lock
        // covers the app from its first frame.
        if (sLocked && [note.object isKindOfClass:[UIWindowScene class]]) {
            APLAttachLockWindow((UIWindowScene *)note.object);
        } else if (sLocked) {
            APLPlaceLockWindow();
        }
    }];

    [center addObserverForName:UISceneDidActivateNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *__unused note) {
        if (sLocked) {
            APLPlaceLockWindow();
        }
    }];
}

static void APLStartListeningForChanges(void) {
    static int token;
    notify_register_dispatch(APLChangedNotificationName().UTF8String, &token, dispatch_get_main_queue(), ^(int __unused note) {
        os_log(TweakLog(), "settings changed, reloading");
        static const double delays[] = {0.5, 2.0};
        APLReapplyAfterChanges(delays, sizeof(delays) / sizeof(delays[0]));
    });
}

#pragma mark - The app

static void APLPrepareForHost(void) {
    if (sPrepared) {
        return;
    }
    sPrepared = YES;

    NSString *bundleID = [NSBundle mainBundle].bundleIdentifier;
    NSString *bundlePath = [NSBundle mainBundle].bundlePath ?: @"";
    BOOL isApp = [bundlePath hasPrefix:@"/private/var/containers/Bundle/Application/"] ||
                 [bundlePath hasPrefix:@"/var/containers/Bundle/Application/"] ||
                 [bundlePath containsString:@"/Applications/"];
    if (bundleID.length == 0 || !isApp) {
        return;  // System UI and extension processes are not apps the pane lists.
    }
    sBundleID = bundleID;
    sAppName = APLHostDisplayName();

    APLApplyStateFromFile();

    // Observers go in now, on the launch path: the app's scene connects before
    // it draws, and that is where the lock window has to be attached.
    APLInstallObservers();

    // The change listener and a second read wait until the run loop is going,
    // in case cfprefsd flushed the pane's last write only after launch.
    dispatch_async(dispatch_get_main_queue(), ^{
        APLStartListeningForChanges();
        static const double delays[] = {0.8};
        APLReapplyAfterChanges(delays, sizeof(delays) / sizeof(delays[0]));
    });
}

#pragma mark - SpringBoard: the Face ID service

// SpringBoard's entitlements carry kTCCServiceFaceID, so the biometric prompt
// has to be asked for from here; the app tells this service which protected
// app is waiting, over the Darwin names in Protect.h.
static NSMutableDictionary<NSString *, NSNumber *> *sAuthListeners;

static NSString *APLDisplayNameForBundle(NSString *bundleID) {
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    if (proxyClass != Nil) {
        id proxy = [(id)proxyClass applicationProxyForIdentifier:bundleID];
        if (proxy != nil) {
            NSString *name = [proxy localizedName];
            if (name.length > 0) {
                return name;
            }
        }
    }
    return bundleID;
}

static void APLPublishAuthResult(NSString *bundleID, uint32_t token, BOOL granted) {
    NSString *name = APLAuthResultName(bundleID);
    int handle = 0;
    if (notify_register_check(name.UTF8String, &handle) != NOTIFY_STATUS_OK) {
        os_log(TweakLog(), "cannot publish Face ID answer for %{public}s", bundleID.UTF8String);
        return;
    }
    notify_set_state(handle, ((uint64_t)token << 1) | (granted ? 1 : 0));
    notify_post(name.UTF8String);
    notify_cancel(handle);
}

static void APLHandleAuthRequest(NSString *bundleID, int handle) {
    uint64_t state = 0;
    if (notify_get_state(handle, &state) != NOTIFY_STATUS_OK) {
        return;
    }
    uint32_t token = (uint32_t)state;
    os_log(TweakLog(), "Face ID requested by %{public}s", bundleID.UTF8String);

    LAContext *context = [[LAContext alloc] init];
    context.localizedCancelTitle = @"取消";
    NSString *reason = [NSString stringWithFormat:@"解锁“%@”", APLDisplayNameForBundle(bundleID)];
    __block BOOL answered = NO;
    [context evaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics
            localizedReason:reason
                      reply:^(BOOL success, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (answered) {
                return;
            }
            answered = YES;
            os_log(TweakLog(), "Face ID for %{public}s success=%d error=%{public}s",
                   bundleID.UTF8String, (int)success, error.localizedDescription.UTF8String ?: "(none)");
            APLPublishAuthResult(bundleID, token, success);
        });
    }];
}

static NSArray<NSString *> *APLAuthBundleIDs(void) {
    NSMutableArray<NSString *> *bundleIDs = [NSMutableArray array];
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (workspaceClass != Nil) {
        id workspace = [(id)workspaceClass defaultWorkspace];
        NSArray *apps = [workspace allInstalledApplications];
        for (id app in apps) {
            NSString *bundleID = [(APLLaunchServicesProxy *)app bundleIdentifier];
            if (bundleID.length > 0) {
                [bundleIDs addObject:bundleID];
            }
        }
    }
    for (NSString *bundleID in APLProtectedBundleIDsInDomain(APLReadSettingsFile())) {
        if (![bundleIDs containsObject:bundleID]) {
            [bundleIDs addObject:bundleID];
        }
    }
    return bundleIDs;
}

static void APLRefreshAuthListeners(void) {
    if (sAuthListeners == nil) {
        sAuthListeners = [NSMutableDictionary dictionary];
    }
    // Every app, not only the protected ones: the pane may have just switched
    // one on, and a request that arrives before this service heard about it
    // would be lost.
    NSArray<NSString *> *bundleIDs = APLAuthBundleIDs();
    os_log(TweakLog(), "auth service listening for %lu app(s)", (unsigned long)bundleIDs.count);

    for (NSString *bundleID in [sAuthListeners allKeys]) {
        if (![bundleIDs containsObject:bundleID]) {
            notify_cancel([sAuthListeners[bundleID] intValue]);
            [sAuthListeners removeObjectForKey:bundleID];
        }
    }
    for (NSString *bundleID in bundleIDs) {
        if (sAuthListeners[bundleID] != nil) {
            continue;
        }
        int handle = 0;
        NSString *name = APLAuthRequestName(bundleID);
        notify_register_dispatch(name.UTF8String, &handle, dispatch_get_main_queue(), ^(int stateHandle) {
            APLHandleAuthRequest(bundleID, stateHandle);
        });
        sAuthListeners[bundleID] = @(handle);
    }

    // The handle stays registered: notifyd drops a name's state once nothing
    // holds the name, and the lock screen reads that state to know this
    // service is up.
    static int serviceHandle;
    if (serviceHandle == 0 && notify_register_check(APLAuthServiceName().UTF8String, &serviceHandle) != NOTIFY_STATUS_OK) {
        os_log(TweakLog(), "cannot publish the auth service");
        serviceHandle = 0;
        return;
    }
    notify_set_state(serviceHandle, 1);
    notify_post(APLAuthServiceName().UTF8String);
}

static void APLSetupSpringBoardService(void) {
    static int changeToken;
    APLRefreshAuthListeners();
    notify_register_dispatch(APLChangedNotificationName().UTF8String, &changeToken, dispatch_get_main_queue(), ^(int __unused note) {
        os_log(TweakLog(), "settings changed, refreshing the auth service");
        // Take the new app in at once, and again once cfprefsd has flushed the
        // settings file this service reads.
        APLRefreshAuthListeners();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            APLRefreshAuthListeners();
        });
    });
}

#pragma mark - Hooking the app's launch

static void (*OriginalRun)(id self, SEL _cmd);

// -[UIApplication _run] is where UIApplicationMain settles before the app's
// own launch callbacks, so the lock is up before the app draws anything.
static BOOL APLIsSpringBoard(void) {
    return [[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"];
}

static void HookedRun(id self, SEL _cmd) {
    if (!APLIsSpringBoard()) {
        APLPrepareForHost();
    }
    if (OriginalRun != NULL) {
        OriginalRun(self, _cmd);
    }
}

__attribute__((constructor)) static void TweakInitialize(void) {
    // Apelin's confirm_loaded looks for this exact marker and build id under
    // the package id's subsystem. Keep the line, and keep it public.
    os_log(TweakLog(), "ApelinLoaded %{public}s in %{public}s", APELIN_BUILD_ID, getprogname());

    // SpringBoard may never run -[UIApplication _run], so its auth service
    // starts from here, on the main queue once its run loop is going.
    if (APLIsSpringBoard()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            APLSetupSpringBoardService();
        });
        return;
    }

    Class applicationClass = objc_getClass("UIApplication");
    if (applicationClass == Nil) {
        return;  // A process without UIKit, whatever the filter said.
    }
    MSHookMessageEx(applicationClass, sel_registerName("_run"), (IMP)HookedRun, (IMP *)&OriginalRun);
}
