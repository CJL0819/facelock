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
#import <objc/message.h>
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
static BOOL sAuthAttemptStarted;
static BOOL sPrepared;
static BOOL sFirstApply = YES;

static void APLWriteUnlockRecord(uint64_t unlockedAt, uint64_t expiry);
static void APLClearUnlockRecord(void);
static uint64_t APLExpiryForCurrentSettings(void);
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

// Wait a moment, then try again while this lock screen is still up and tries
// remain. Without this the three tries would need three separate triggers.
- (void)scheduleAutomaticRetry {
    if (_autoAttempts >= 3) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf.view.window == nil) {
            return;  // unlocked, or the lock screen is gone
        }
        if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
            return;  // the app left the foreground: never prompt from behind it
        }
        [strongSelf requestFaceIDAutomatic:YES];
    });
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
        if ((uint32_t)(state >> 2) != token) {
            return;  // An older request's answer.
        }
        notify_cancel(stateHandle);
        self->_resultHandle = 0;
        if (!self->_authenticating) {
            return;
        }
        self->_authenticating = NO;
        BOOL granted = (state & 1) != 0;
        BOOL cancelled = (state & 2) != 0;
        os_log(TweakLog(), "Face ID answer granted=%d cancelled=%d automatic=%d",
               (int)granted, (int)cancelled, (int)self->_requestWasAutomatic);
        if (granted) {
            self->_autoAttempts = 0;
            [self setStatusText:nil];
            if (self.onUnlocked) {
                self.onUnlocked();
            }
        } else if (cancelled) {
            // The person said no: stop asking on their behalf and leave them
            // the two buttons.
            self->_autoAttempts = 3;
            [self setStatusText:nil];
        } else if (self->_requestWasAutomatic) {
            // A failed automatic try hands over quietly to the user, unless
            // there are tries left.
            self->_autoAttempts += 1;
            [self setStatusText:nil];
            [self scheduleAutomaticRetry];
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
            [strongSelf scheduleAutomaticRetry];
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
            sAuthAttemptStarted = NO;
            APLWriteUnlockRecord((uint64_t)[NSDate date].timeIntervalSince1970, APLExpiryForCurrentSettings());
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
static void APLPromptIfNeeded(void);  // only when the app is in front

static void APLLockApp(void) {
    sLocked = YES;
    sAuthAttemptStarted = NO;
    [sLockController resetAutoAttempts];
    APLShowLock();
    APLPromptIfNeeded();
}

// One automatic attempt per lock, and only with the app in front: a prompt
// asked for by a background app keeps the sensor running over whatever is on
// screen.
static void APLPromptIfNeeded(void) {
    if (!sLocked || sAuthAttemptStarted || sLockController == nil) {
        return;
    }
    // Only prompt with the app in front: a prompt a backgrounded app asked for
    // would hold the sensor open over whatever is on screen.
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        os_log(TweakLog(), "not prompting: app is not in front");
        return;
    }
    sAuthAttemptStarted = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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

// A stamp far in the future stands for "no expiry": the lock delay is off.
static const uint64_t APLUnlockNeverExpires = 4102444800ULL;  // 2100-01-01

// The app's own container, so the record outlives the process: after iOS kills
// a backgrounded app, opening it again inside the delay must not ask again.
static NSString *APLUnlockRecordPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/com.404.facelock.unlock"];
}

static uint64_t APLDeviceLockStamp(void) {
    int handle = 0;
    if (notify_register_check(APLDeviceLockStampName().UTF8String, &handle) != NOTIFY_STATUS_OK) {
        return 0;
    }
    uint64_t state = 0;
    notify_get_state(handle, &state);
    notify_cancel(handle);
    return state;
}

static void APLClearUnlockRecord(void) {
    [[NSFileManager defaultManager] removeItemAtPath:APLUnlockRecordPath() error:NULL];
}

// "<unlocked at> <valid until>": the first number lets a launch tell whether a
// device lock happened since, even one this app slept through.
static void APLWriteUnlockRecord(uint64_t unlockedAt, uint64_t expiry) {
    if (expiry == 0) {
        APLClearUnlockRecord();
        return;
    }
    NSString *text = [NSString stringWithFormat:@"%llu %llu", unlockedAt, expiry];
    [text writeToFile:APLUnlockRecordPath() atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

static BOOL APLReadUnlockRecord(uint64_t *unlockedAt, uint64_t *expiry) {
    NSString *text = [NSString stringWithContentsOfFile:APLUnlockRecordPath() encoding:NSUTF8StringEncoding error:NULL];
    if (text == nil) {
        return NO;
    }
    unsigned long long unlocked = 0;
    unsigned long long until = 0;
    if (sscanf(text.UTF8String, "%llu %llu", &unlocked, &until) != 2) {
        return NO;
    }
    if (unlockedAt != NULL) {
        *unlockedAt = (uint64_t)unlocked;
    }
    if (expiry != NULL) {
        *expiry = (uint64_t)until;
    }
    return YES;
}

// When the app was unlocked, how long that holds: 0 for the immediate lock
// (verify every launch), none for 不锁定, otherwise the chosen wait.
static uint64_t APLExpiryForCurrentSettings(void) {
    if (sLockDelay == 0) {
        return 0;
    }
    if (sLockDelay < 0) {
        return APLUnlockNeverExpires;
    }
    return (uint64_t)[NSDate date].timeIntervalSince1970 + (uint64_t)sLockDelay;
}

static BOOL APLUnlockRecordStillHolds(void) {
    uint64_t unlockedAt = 0;
    uint64_t expiry = 0;
    if (!APLReadUnlockRecord(&unlockedAt, &expiry) || expiry == 0) {
        return NO;
    }
    uint64_t locked = APLDeviceLockStamp();
    if (locked > unlockedAt) {
        os_log(TweakLog(), "the device locked since that unlock");
        return NO;
    }
    if (expiry >= APLUnlockNeverExpires) {
        return YES;
    }
    return (uint64_t)[NSDate date].timeIntervalSince1970 < expiry;
}

static void APLApplyDomain(NSDictionary *domain, BOOL enabled, BOOL protected) {
    if (sBundleID.length == 0) {
        return;
    }
    BOOL wasProtected = sProtected;
    BOOL firstApply = sFirstApply;
    sFirstApply = NO;
    sEnabled = enabled;
    sProtected = protected;
    sLockDelay = domain != nil ? APLIntegerInDomain(domain, APLKeyForLockDelay(), 0) : 0;
    sLockOnDeviceLock = domain != nil ? APLBoolInDomain(domain, APLKeyForLockOnDeviceLock(), YES) : YES;
    os_log(TweakLog(), "state enabled=%d protected=%d delay=%ld deviceLock=%d",
           (int)sEnabled, (int)sProtected, (long)sLockDelay, (int)sLockOnDeviceLock);

    if (!(sEnabled && sProtected)) {
        APLClearUnlockRecord();
        if (sLocked) {
            sLocked = NO;
            sAuthAttemptStarted = NO;
            APLHideLockWindow();
        }
        return;
    }
    if (!wasProtected) {
        // A launch inside the delay the pane set does not ask again, even if
        // iOS ended the app in the background since; turning protection on now
        // always locks.
        BOOL recordHolds = firstApply && APLUnlockRecordStillHolds();
        if (recordHolds && sLockDelay == 0) {
            recordHolds = NO;  // "立即": every launch asks
        }
        if (recordHolds && sLockDelay > 0) {
            uint64_t unlockedAt = 0;
            uint64_t expiry = 0;
            if (APLReadUnlockRecord(&unlockedAt, &expiry) && expiry >= APLUnlockNeverExpires) {
                recordHolds = NO;  // written while the delay was off, now it is on
            }
        }
        if (recordHolds) {
            os_log(TweakLog(), "still unlocked from an earlier session");
            sLocked = NO;
            APLHideLockWindow();
            return;
        }
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
    // The pane's signal covers the moment before cfprefsd has flushed the file.
    // Once the file holds a value for this app, that value is the answer: a
    // signal left over from an earlier switch off would lock it for good.
    BOOL fileSaysIt = domain != nil && domain[APLKeyForBundle(sBundleID)] != nil;
    if (!protected && !fileSaysIt && APLNotifySaysProtected(sBundleID)) {
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
        // Read the settings again on every return to the front: a switch turned
        // off from the home screen's menu must end the lock even though this
        // process still remembers being protected.
        APLApplyStateFromFile();
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
        APLClearUnlockRecord();  // the device lock ends the app's grace period
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

static void APLPublishAuthResult(NSString *bundleID, uint32_t token, BOOL granted, BOOL cancelled) {
    NSString *name = APLAuthResultName(bundleID);
    int handle = 0;
    if (notify_register_check(name.UTF8String, &handle) != NOTIFY_STATUS_OK) {
        os_log(TweakLog(), "cannot publish Face ID answer for %{public}s", bundleID.UTF8String);
        return;
    }
    // token << 2 | granted | cancelled << 1: the lock screen stops its
    // automatic tries when the person cancelled the system dialog.
    notify_set_state(handle, ((uint64_t)token << 2) | (granted ? 1 : 0) | (cancelled ? 2 : 0));
    notify_post(name.UTF8String);
    notify_cancel(handle);
}

// One evaluation per app at a time: a second prompt over a live one leaves the
// sensor scanning and makes the dialog close and come back on its own. The slot
// holds an LAContext, or the island's matcher when 简化面容识别动画 is on.
static NSMutableDictionary<NSString *, id> *sAuthContexts;
static NSMutableDictionary<NSString *, NSNumber *> *sAuthContextTokens;

static void APLStartAuthEvaluationWithLA(NSString *bundleID, uint32_t token);
static void APLStartIslandAuth(NSString *bundleID, uint32_t token);
static BOOL APLSimpleFaceIDEnabled(void);

static void APLStartAuthEvaluation(NSString *bundleID, uint32_t token) {
    os_log(TweakLog(), "Face ID requested by %{public}s", bundleID.UTF8String);
    if (APLSimpleFaceIDEnabled()) {
        APLStartIslandAuth(bundleID, token);
        return;
    }
    APLStartAuthEvaluationWithLA(bundleID, token);
}

static void APLStartAuthEvaluationWithLA(NSString *bundleID, uint32_t token) {
    LAContext *context = [[LAContext alloc] init];
    context.localizedCancelTitle = @"取消";
    sAuthContexts[bundleID] = context;
    sAuthContextTokens[bundleID] = @(token);

    NSString *reason = [NSString stringWithFormat:@"解锁“%@”", APLDisplayNameForBundle(bundleID)];
    [context evaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics
            localizedReason:reason
                      reply:^(BOOL success, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (sAuthContexts[bundleID] != context) {
                return;  // a newer request took over
            }
            [sAuthContexts removeObjectForKey:bundleID];
            [sAuthContextTokens removeObjectForKey:bundleID];
            os_log(TweakLog(), "Face ID for %{public}s success=%d error=%{public}s",
                   bundleID.UTF8String, (int)success, error.localizedDescription.UTF8String ?: "(none)");
            APLPublishAuthResult(bundleID, token, success, error.code == LAErrorUserCancel);
        });
    }];

    // iOS keeps its sheet up after a failed match, with its own retry inside it.
    // This gives one attempt a life of its own: when nothing comes back in three
    // seconds, close the sheet and answer, so the lock screen opens a fresh one.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (sAuthContexts[bundleID] != context) {
            return;  // answered, or replaced by a newer request
        }
        os_log(TweakLog(), "closing an unanswered Face ID dialog for %{public}s", bundleID.UTF8String);
        [sAuthContexts removeObjectForKey:bundleID];
        [sAuthContextTokens removeObjectForKey:bundleID];
        [context invalidate];
        APLPublishAuthResult(bundleID, token, NO, NO);
    });
}

static void APLHandleAuthRequest(NSString *bundleID, int handle) {
    uint64_t state = 0;
    if (notify_get_state(handle, &state) != NOTIFY_STATUS_OK) {
        return;
    }
    uint32_t token = (uint32_t)state;

    if (sAuthContexts == nil) {
        sAuthContexts = [NSMutableDictionary dictionary];
        sAuthContextTokens = [NSMutableDictionary dictionary];
    }
    NSNumber *running = sAuthContextTokens[bundleID];
    if (running != nil) {
        if (running.unsignedIntValue == token) {
            os_log(TweakLog(), "ignoring a repeated Face ID request from %{public}s", bundleID.UTF8String);
            return;  // the same request, asked twice
        }
        LAContext *stale = sAuthContexts[bundleID];
        [sAuthContexts removeObjectForKey:bundleID];
        [sAuthContextTokens removeObjectForKey:bundleID];
        [stale invalidate];  // close the dialog that is up
        APLPublishAuthResult(bundleID, running.unsignedIntValue, NO, NO);

        // Give the dialog time to leave the screen before the next one opens,
        // so a retry does not look like one dialog flickering into another.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (sAuthContextTokens[bundleID] != nil) {
                return;  // another request arrived meanwhile
            }
            APLStartAuthEvaluation(bundleID, token);
        });
        return;
    }

    APLStartAuthEvaluation(bundleID, token);
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

// SpringBoard runs from boot to shutdown, so its stamp of the last device lock
// is what a suspended or killed app can still be held to.
static BOOL APLDeviceIsReallyLocked(void) {
    Class lockScreenClass = NSClassFromString(@"SBLockScreenManager");
    if (lockScreenClass == Nil) {
        return YES;  // nothing to ask: keep the old behaviour
    }
    SEL sharedSelector = NSSelectorFromString(@"sharedInstanceIfExists");
    if (![lockScreenClass respondsToSelector:sharedSelector]) {
        return YES;
    }
    id manager = ((id (*)(id, SEL))objc_msgSend)(lockScreenClass, sharedSelector);
    SEL lockedSelector = NSSelectorFromString(@"isUILocked");
    if (manager == nil || ![manager respondsToSelector:lockedSelector]) {
        return YES;
    }
    return ((BOOL (*)(id, SEL))objc_msgSend)(manager, lockedSelector);
}

static void APLPublishDeviceLockStamp(void) {
    static int handle;
    if (handle == 0 && notify_register_check(APLDeviceLockStampName().UTF8String, &handle) != NOTIFY_STATUS_OK) {
        os_log(TweakLog(), "cannot publish the device lock stamp");
        handle = 0;
        return;
    }
    notify_set_state(handle, (uint64_t)[NSDate date].timeIntervalSince1970);
    notify_post(APLDeviceLockStampName().UTF8String);
    os_log(TweakLog(), "device lock stamped");
}

// `com.apple.springboard.lockcomplete` also arrives when the cover sheet comes
// down over an app — Notification Center, that is — which is not a lock at all.
// Only stamp when the device is really locked, once SpringBoard has settled.
static void APLNotePossibleDeviceLock(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!APLDeviceIsReallyLocked()) {
            os_log(TweakLog(), "not a device lock, stamp left alone");
            return;
        }
        APLPublishDeviceLockStamp();
    });
}



static UIContextMenuConfiguration *(*OriginalIconContextMenu)(id self, SEL _cmd, id interaction, CGPoint location);
static id HookedIconContextMenu(id self, SEL _cmd, id interaction, CGPoint location);
static void (*OriginalOpenFolder)(id self, SEL _cmd, id folderIcon, id location, BOOL animated, id completion);
static void HookedOpenFolder(id self, SEL _cmd, id folderIcon, id location, BOOL animated, id completion);
static NSString *APLFolderIdentifierForIconView(id iconView);

/// SpringBoard's answer to the pane's "may I turn this lock off".
static void APLPublishVerifyResult(uint32_t token, BOOL granted) {
    static int handle;
    if (handle == 0 && notify_register_check(APLVerifyResultName().UTF8String, &handle) != NOTIFY_STATUS_OK) {
        os_log(TweakLog(), "cannot publish the verify answer");
        handle = 0;
        return;
    }
    notify_set_state(handle, ((uint64_t)token << 1) | (granted ? 1 : 0));
    notify_post(APLVerifyResultName().UTF8String);
}

#pragma mark - The island's own Face ID check

static void APLAskForVerification(NSString *reason, void (^answer)(BOOL granted));
static void APLAskForVerificationWithSystemUI(NSString *reason, void (^answer)(BOOL granted));

// With 简化面容识别动画 on, the check is done with BiometricKit directly, so iOS
// never draws its own square sheet, and the island is stretched by us instead.

static BOOL APLSimpleFaceIDEnabled(void) {
    NSDictionary *domain = APLReadSettingsFile();
    return domain != nil ? APLBoolInDomain(domain, APLKeyForSimpleFaceID(), NO) : NO;
}

/// A black pill where the island is, grown to the right while the check runs,
/// with the padlock on its right edge. Its height never changes.
@interface APLIslandPrompt : NSObject
+ (instancetype)shared;
- (void)showWorking;
- (void)showResult:(BOOL)success;
- (void)hideSilently;
@end

@implementation APLIslandPrompt {
    UIWindow *_window;
    UIView *_pill;
    UIImageView *_icon;
    CGFloat _baseWidth;
    CGFloat _height;
}

+ (instancetype)shared {
    static APLIslandPrompt *prompt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        prompt = [[APLIslandPrompt alloc] init];
    });
    return prompt;
}

- (void)buildIfNeeded {
    if (_window != nil) {
        return;
    }
    UIScreen *screen = [UIScreen mainScreen] ?: [UIScreen screens].firstObject;
    CGRect bounds = screen.bounds;
    // The island on this device: 126 x 37.33 at 11 pt from the top.
    _height = 37.33;
    _baseWidth = 126.0;
    CGFloat top = 11.0;

    UIWindow *window = [[UIWindow alloc] initWithFrame:bounds];
    window.windowLevel = UIWindowLevelAlert + 200;
    window.backgroundColor = [UIColor clearColor];
    window.userInteractionEnabled = NO;
    UIViewController *root = [[UIViewController alloc] init];
    root.view.backgroundColor = [UIColor clearColor];
    root.view.userInteractionEnabled = NO;
    window.rootViewController = root;
    window.hidden = NO;

    CGFloat width = _baseWidth;
    UIView *pill = [[UIView alloc] initWithFrame:CGRectMake((bounds.size.width - width) / 2.0,
                                                           top,
                                                           width,
                                                           _height)];
    pill.backgroundColor = [UIColor blackColor];
    pill.layer.cornerRadius = _height / 2.0;
    pill.clipsToBounds = YES;
    pill.userInteractionEnabled = NO;
    [root.view addSubview:pill];

    UIImage *padlock = [UIImage systemImageNamed:@"lock.open.fill"];
    UIImageView *icon = [[UIImageView alloc] initWithImage:
                         [padlock imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
    icon.tintColor = [UIColor whiteColor];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.alpha = 0.0;
    [pill addSubview:icon];

    _window = window;
    _pill = pill;
    _icon = icon;
}

- (void)showWorking {
    [self buildIfNeeded];
    UIScreen *screen = [UIScreen mainScreen] ?: [UIScreen screens].firstObject;
    CGFloat width = 214.0;
    [UIView animateWithDuration:0.28
                          delay:0.0
         usingSpringWithDamping:0.85
          initialSpringVelocity:0.4
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        CGRect frame = self->_pill.frame;
        frame.size.width = width;
        frame.origin.x = (screen.bounds.size.width - width) / 2.0;
        self->_pill.frame = frame;
        CGRect iconFrame = CGRectMake(width - self->_height - 8.0,
                                      (self->_height - 18.0) / 2.0,
                                      18.0,
                                      18.0);
        self->_icon.frame = iconFrame;
        self->_icon.alpha = 0.55;
    } completion:nil];
}

- (void)showResult:(BOOL)success {
    if (_window == nil) {
        return;
    }
    UIImage *image = [UIImage systemImageNamed:(success ? @"checkmark" : @"xmark")];
    _icon.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    _icon.tintColor = success ? [UIColor colorWithRed:0.20 green:0.85 blue:0.45 alpha:1.0]
                              : [UIColor colorWithRed:1.0 green:0.35 blue:0.32 alpha:1.0];
    _icon.alpha = 1.0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self hide];
    });
}

- (void)hide {
    UIScreen *screen = [UIScreen mainScreen] ?: [UIScreen screens].firstObject;
    [UIView animateWithDuration:0.25
                     animations:^{
        CGRect frame = self->_pill.frame;
        frame.size.width = self->_baseWidth;
        frame.origin.x = (screen.bounds.size.width - self->_baseWidth) / 2.0;
        self->_pill.frame = frame;
        self->_icon.alpha = 0.0;
    } completion:^(BOOL __unused finished) {
        self->_window.hidden = YES;
        self->_window = nil;
        [self->_pill removeFromSuperview];
        self->_pill = nil;
        self->_icon = nil;
    }];
}

- (void)hideSilently {
    [self hide];
}

@end

/// Runs the match, telling the caller whether Face ID said yes. `unavailable`
/// is set when the device would not start a match at all, so the caller can
/// fall back to the system prompt.
@interface APLBiometricMatcher : NSObject
@property (nonatomic, copy) void (^completion)(BOOL success, BOOL unavailable);
@property (nonatomic, strong) id operation;
@property (nonatomic, assign) BOOL finished;
@end

@implementation APLBiometricMatcher

- (void)start {
    Class managerClass = NSClassFromString(@"BKDeviceManager");
    NSArray *devices = nil;
    // BiometricKit answers with +availableDevices (and +availableDevicesWithFailure:).
    SEL available = NSSelectorFromString(@"availableDevices");
    if (managerClass != Nil && [managerClass respondsToSelector:available]) {
        devices = ((id (*)(id, SEL))objc_msgSend)(managerClass, available);
    } else {
        SEL availableWithFailure = NSSelectorFromString(@"availableDevicesWithFailure:");
        if (managerClass != Nil && [managerClass respondsToSelector:availableWithFailure]) {
            BOOL failed = NO;
            devices = ((id (*)(id, SEL, BOOL *))objc_msgSend)(managerClass, availableWithFailure, &failed);
        }
    }
    if (![devices isKindOfClass:[NSArray class]] || devices.count == 0) {
        os_log(TweakLog(), "no biometric device, falling back");
        [self finish:NO unavailable:YES];
        return;
    }
    id device = devices.firstObject;
    SEL createSelector = NSSelectorFromString(@"createMatchOperationWithError:");
    if (![device respondsToSelector:createSelector]) {
        [self finish:NO unavailable:YES];
        return;
    }
    NSError *error = nil;
    id operation = ((id (*)(id, SEL, NSError **))objc_msgSend)(device, createSelector, &error);
    if (operation == nil) {
        os_log(TweakLog(), "cannot create the match operation: %{public}s",
               error.localizedDescription.UTF8String ?: "(none)");
        [self finish:NO unavailable:YES];
        return;
    }
    self.operation = operation;
    if ([operation respondsToSelector:NSSelectorFromString(@"setDelegate:")]) {
        [operation performSelector:NSSelectorFromString(@"setDelegate:") withObject:self];
    }
    if ([operation respondsToSelector:NSSelectorFromString(@"setQueue:")]) {
        [operation performSelector:NSSelectorFromString(@"setQueue:") withObject:dispatch_get_main_queue()];
    }
    SEL startSelector = NSSelectorFromString(@"startWithError:");
    if (![operation respondsToSelector:startSelector]) {
        [self finish:NO unavailable:YES];
        return;
    }
    NSError *startError = nil;
    BOOL started = ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(operation, startSelector, &startError);
    os_log(TweakLog(), "island match started=%d error=%{public}s",
           (int)started, startError.localizedDescription.UTF8String ?: "(none)");
    if (!started) {
        [self finish:NO unavailable:YES];
        return;
    }
    // Never leave the person stuck: if nothing comes back, the system prompt is
    // asked instead.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.finished) {
            return;
        }
        os_log(TweakLog(), "match timed out");
        if ([self.operation respondsToSelector:NSSelectorFromString(@"cancel")]) {
            [self.operation performSelector:NSSelectorFromString(@"cancel")];
        }
        [self finish:NO unavailable:YES];
    });
}

- (void)finish:(BOOL)success unavailable:(BOOL)unavailable {
    if (self.finished) {
        return;
    }
    self.finished = YES;
    self.operation = nil;
    void (^completion)(BOOL, BOOL) = self.completion;
    self.completion = nil;
    if (completion != nil) {
        completion(success, unavailable);
    }
}

- (void)stopOperation {
    if ([self.operation respondsToSelector:NSSelectorFromString(@"cancel")]) {
        [self.operation performSelector:NSSelectorFromString(@"cancel")];
    }
}

// BiometricKit's delegate callbacks. Success is result 1 (BKMatchResultSuccess).
- (void)matchResult:(id)resultInfo details:(id __unused)details client:(id __unused)client {
    NSInteger result = 0;
    if ([resultInfo respondsToSelector:NSSelectorFromString(@"result")]) {
        result = [[resultInfo performSelector:NSSelectorFromString(@"result")] integerValue];
    }
    os_log(TweakLog(), "match result %ld", (long)result);
    if (result == 1) {
        [self stopOperation];
        [self finish:YES unavailable:NO];
    }
}

- (void)operationEndsWithReason:(NSInteger)reason {
    os_log(TweakLog(), "match ended, reason %ld", (long)reason);
    [self finish:NO unavailable:NO];
}

- (void)operationInterrupted {
    os_log(TweakLog(), "match interrupted");
    [self finish:NO unavailable:NO];
}

/// Drops the check without answering: the watchdog has answered already.
- (void)abandon {
    self.finished = YES;
    self.completion = nil;
    [self stopOperation];
    self.operation = nil;
}

@end

static APLBiometricMatcher *sIslandMatcher;

/// A protected app's request, answered from the island instead of the system
/// sheet. Falls back to the system sheet when the match cannot even start.
static void APLStartIslandAuth(NSString *bundleID, uint32_t token) {
    APLIslandPrompt *prompt = [APLIslandPrompt shared];
    [prompt showWorking];
    APLBiometricMatcher *matcher = [[APLBiometricMatcher alloc] init];
    sAuthContexts[bundleID] = matcher;
    sAuthContextTokens[bundleID] = @(token);
    matcher.completion = ^(BOOL success, BOOL unavailable) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (sAuthContexts[bundleID] != matcher) {
                return;  // answered, or a newer request took over
            }
            [sAuthContexts removeObjectForKey:bundleID];
            [sAuthContextTokens removeObjectForKey:bundleID];
            if (unavailable) {
                [prompt hideSilently];
                os_log(TweakLog(), "island check unavailable for %{public}s", bundleID.UTF8String);
                APLStartAuthEvaluationWithLA(bundleID, token);
                return;
            }
            [prompt showResult:success];
            APLPublishAuthResult(bundleID, token, success, NO);
        });
    };
    [matcher start];

    // One attempt gets three seconds, as the system sheet did.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (sAuthContexts[bundleID] != matcher) {
            return;
        }
        os_log(TweakLog(), "island check timed out for %{public}s", bundleID.UTF8String);
        [sAuthContexts removeObjectForKey:bundleID];
        [sAuthContextTokens removeObjectForKey:bundleID];
        [matcher abandon];
        [prompt hideSilently];
        APLPublishAuthResult(bundleID, token, NO, NO);
    });
}

static void APLAskWithIsland(void (^answer)(BOOL success, BOOL unavailable)) {
    APLIslandPrompt *prompt = [APLIslandPrompt shared];
    [prompt showWorking];
    APLBiometricMatcher *matcher = [[APLBiometricMatcher alloc] init];
    sIslandMatcher = matcher;
    matcher.completion = ^(BOOL success, BOOL unavailable) {
        sIslandMatcher = nil;
        if (!unavailable) {
            [prompt showResult:success];
        } else {
            [prompt showResult:NO];
        }
        answer(success, unavailable);
    };
    [matcher start];
}

static void APLAskForVerification(NSString *reason, void (^answer)(BOOL granted)) {
    if (APLSimpleFaceIDEnabled()) {
        APLAskWithIsland(^(BOOL success, BOOL unavailable) {
            if (unavailable) {
                // Nothing to draw the answer with: let iOS ask.
                APLAskForVerificationWithSystemUI(reason, answer);
                return;
            }
            answer(success);
        });
        return;
    }
    APLAskForVerificationWithSystemUI(reason, answer);
}

static void APLAskForVerificationWithSystemUI(NSString *reason, void (^answer)(BOOL granted)) {
    LAContext *context = [[LAContext alloc] init];
    context.localizedFallbackTitle = @"使用密码";
    [context evaluatePolicy:LAPolicyDeviceOwnerAuthentication
            localizedReason:reason
                      reply:^(BOOL success, NSError *error) {
        os_log(TweakLog(), "verification success=%d error=%{public}s",
               (int)success, error.localizedDescription.UTF8String ?: "(none)");
        answer(success);
    }];
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

    // The pane asks here before it turns a lock off.
    static int verifyHandle;
    static uint32_t lastVerifyToken;
    notify_register_dispatch(APLVerifyRequestName().UTF8String, &verifyHandle, dispatch_get_main_queue(), ^(int stateHandle) {
        uint64_t state = 0;
        if (notify_get_state(stateHandle, &state) != NOTIFY_STATUS_OK) {
            return;
        }
        uint32_t token = (uint32_t)state;
        if (token == 0 || token == lastVerifyToken) {
            return;
        }
        lastVerifyToken = token;
        os_log(TweakLog(), "asked to verify turning a lock off, token %u", token);
        APLAskForVerification(@"关闭应用面容锁", ^(BOOL granted) {
            APLPublishVerifyResult(token, granted);
        });
    });

    // SpringBoard's own lock notifications, plus the one UIKit posts when the
    // passcode-protected data goes away.
    static int lockToken;
    notify_register_dispatch("com.apple.springboard.lockcomplete", &lockToken, dispatch_get_main_queue(), ^(int __unused note) {
        APLNotePossibleDeviceLock();
    });
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationProtectedDataWillBecomeUnavailable
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *__unused note) {
        APLNotePossibleDeviceLock();
    }];

    // An app installed after the service started would have no listener, so its
    // Face ID request would go nowhere: refresh the list when the device comes
    // back from the lock screen, at most every half minute.
    static NSTimeInterval lastRefresh;
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *__unused note) {
        NSTimeInterval now = [NSDate date].timeIntervalSince1970;
        if (now - lastRefresh < 30.0) {
            return;
        }
        lastRefresh = now;
        APLRefreshAuthListeners();
    }];

    // Warm the biometric service, so the first prompt after a launch does not
    // pay for opening that connection.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        LAContext *warm = [[LAContext alloc] init];
        NSError *warmError = nil;
        [warm canEvaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics error:&warmError];
    });


    // A long press on a home screen icon offers a switch for that app's lock.
    Class iconViewClass = NSClassFromString(@"SBIconView");
    if (iconViewClass != Nil) {
        MSHookMessageEx(iconViewClass,
                        sel_registerName("contextMenuInteraction:configurationForMenuAtLocation:"),
                        (IMP)HookedIconContextMenu,
                        (IMP *)&OriginalIconContextMenu);
    } else {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            Class lateClass = NSClassFromString(@"SBIconView");
            if (lateClass != Nil) {
                MSHookMessageEx(lateClass,
                                sel_registerName("contextMenuInteraction:configurationForMenuAtLocation:"),
                                (IMP)HookedIconContextMenu,
                                (IMP *)&OriginalIconContextMenu);
            }
        });
    }

    // A folder holding a protected app opens only after Face ID.
    Class iconManagerClass = NSClassFromString(@"SBHIconManager");
    if (iconManagerClass != Nil) {
        MSHookMessageEx(iconManagerClass,
                        sel_registerName("openFolderIcon:location:animated:withCompletion:"),
                        (IMP)HookedOpenFolder,
                        (IMP *)&OriginalOpenFolder);
    }
}

#pragma mark - The home screen's long press menu

// The icon's app. A folder or a widget answers nothing, and keeps the item off.
static NSString *APLBundleIdentifierForIconView(id iconView) {
    if (![iconView respondsToSelector:sel_registerName("icon")]) {
        return nil;
    }
    id icon = [iconView performSelector:sel_registerName("icon")];
    if (icon == nil) {
        return nil;
    }
    if (![icon respondsToSelector:sel_registerName("application")]) {
        return nil;
    }
    id application = [icon performSelector:sel_registerName("application")];
    if (application == nil || ![application respondsToSelector:sel_registerName("bundleIdentifier")]) {
        return nil;
    }
    id bundleID = [application performSelector:sel_registerName("bundleIdentifier")];
    return [bundleID isKindOfClass:[NSString class]] && [bundleID length] > 0 ? bundleID : nil;
}

/// The long press menu writes this from SpringBoard, so it publishes the app's
/// protection state too: an app that is running reads that name as quickly as
/// the settings file, and a stale "protected" there would keep it locked.
static void APLPublishProtectionState(NSString *bundleID, BOOL on) {
    static NSMutableDictionary<NSString *, NSNumber *> *handles;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handles = [NSMutableDictionary dictionary];
    });
    int handle = [handles[bundleID] intValue];
    if (handle == 0) {
        if (notify_register_check(APLProtectionStateName(bundleID).UTF8String, &handle) != NOTIFY_STATUS_OK) {
            return;
        }
        handles[bundleID] = @(handle);
    }
    notify_set_state(handle, on ? 1 : 0);
    notify_post(APLProtectionStateName(bundleID).UTF8String);
}

// The domain the pane writes, written the way the tweak reads it. cfprefsd keeps
// its own copy, so the toggle reaches the apps through the changed notification.
static BOOL APLWriteLockValue(NSString *key, id value);

static BOOL APLWriteLockKey(NSString *key, BOOL on) {
    return APLWriteLockValue(key, @(on));
}

static BOOL APLWriteLockValue(NSString *key, id value) {
    NSString *name = [APLPreferencesDomain() stringByAppendingString:@".plist"];
    NSString *path = ApelinBootstrapPath([@"/var/mobile/Library/Preferences/" stringByAppendingString:name]);
    if (path.length == 0) {
        path = [@"/var/mobile/Library/Preferences/" stringByAppendingString:name];
    }
    NSMutableDictionary *domain = [NSMutableDictionary dictionaryWithDictionary:APLReadSettingsFile() ?: @{}];
    domain[key] = value;
    if (![domain writeToFile:path atomically:YES]) {
        os_log(TweakLog(), "the quick toggle could not save %{public}s", key.UTF8String);
        return NO;
    }
    notify_post(APLChangedNotificationName().UTF8String);
    return YES;
}

static void APLWriteProtectionForBundle(NSString *bundleID, BOOL on) {
    if (APLWriteLockKey(APLKeyForBundle(bundleID), on)) {
        APLPublishProtectionState(bundleID, on);
        os_log(TweakLog(), "quick toggle %{public}s protected=%d", bundleID.UTF8String, (int)on);
    }
}

static id HookedIconContextMenu(id self, SEL _cmd, id interaction, CGPoint location) {
    UIContextMenuConfiguration *configuration = OriginalIconContextMenu(self, _cmd, interaction, location);
    if (configuration == nil) {
        return nil;
    }
    NSString *bundleID = APLBundleIdentifierForIconView(self);
    NSString *folderID = bundleID.length == 0 ? APLFolderIdentifierForIconView(self) : nil;
    if (bundleID.length == 0 && folderID.length == 0) {
        return configuration;
    }

    @try {
        id originalProvider = [configuration valueForKey:@"actionProvider"];
        if (originalProvider == nil) {
            return configuration;
        }
        BOOL isOn = bundleID.length > 0
            ? APLBoolInDomain(APLReadSettingsFile(), APLKeyForBundle(bundleID), NO)
            : APLBoolInDomain(APLReadSettingsFile(), APLKeyForFolder(folderID), NO);
        NSString *onTitle = bundleID.length > 0 ? @"开启应用面容锁" : @"锁定文件夹";
        NSString *offTitle = bundleID.length > 0 ? @"关闭应用面容锁" : @"取消文件夹锁定";
        NSString *reason = bundleID.length > 0 ? @"关闭应用面容锁" : @"取消文件夹锁定";
        UIImage *itemImage = [UIImage systemImageNamed:(bundleID.length > 0 ? @"faceid" : @"lock.fill")];
        UIMenu *(^originalMenu)(void) = originalProvider;
        id provider = ^UIMenu *(void) {
            UIMenu *menu = originalMenu();
            UIAction *action = [UIAction actionWithTitle:(isOn ? offTitle : onTitle)
                                                   image:itemImage
                                              identifier:nil
                                                 handler:^(UIAction *__unused tapped) {
                if (!isOn) {
                    if (bundleID.length > 0) {
                        APLWriteProtectionForBundle(bundleID, YES);
                    } else {
                        APLWriteLockKey(APLKeyForFolder(folderID), YES);
                        os_log(TweakLog(), "folder locked, %{public}s", folderID.UTF8String);
                    }
                    return;
                }
                APLAskForVerification(reason, ^(BOOL granted) {
                    if (!granted) {
                        return;
                    }
                    if (bundleID.length > 0) {
                        APLWriteProtectionForBundle(bundleID, NO);
                    } else {
                        APLWriteLockKey(APLKeyForFolder(folderID), NO);
                        os_log(TweakLog(), "folder unlocked, %{public}s", folderID.UTF8String);
                    }
                });
            }];
            NSMutableArray *children = [NSMutableArray array];
            if (menu != nil) {
                [children addObjectsFromArray:menu.children];
            }
            // Last, not first: the first section of an icon's menu sits against
            // the app preview, where a tap may open the app instead.
            [children addObject:action];
            if (menu != nil) {
                return [menu menuByReplacingChildren:children];
            }
            return [UIMenu menuWithTitle:@"" children:children];
        };
        return [UIContextMenuConfiguration configurationWithIdentifier:[configuration identifier]
                                                      previewProvider:[configuration valueForKey:@"previewProvider"]
                                                       actionProvider:provider];
    } @catch (NSException *exception) {
        os_log(TweakLog(), "the long press menu kept its own actions: %{public}s", exception.reason.UTF8String ?: "");
        return configuration;
    }
}

#pragma mark - The home screen's folders

/// What a folder is called in the settings domain: SpringBoard's own name for
/// the folder when it has one, its display name otherwise.
static NSString *APLFolderIdentifierForIconView(id iconView) {
    if (iconView == nil) {
        return nil;
    }
    // Called with an icon view from the menu, and with the folder icon itself
    // when a folder is being opened.
    id icon = iconView;
    if ([iconView respondsToSelector:sel_registerName("icon")]) {
        icon = [iconView performSelector:sel_registerName("icon")];
    }
    if (icon == nil || ![icon respondsToSelector:sel_registerName("folder")]) {
        return nil;
    }
    id folder = [icon performSelector:sel_registerName("folder")];
    if (folder == nil) {
        return nil;
    }
    for (NSString *selectorName in @[@"uniqueIdentifier", @"folderIdentifier", @"displayName"]) {
        SEL selector = sel_registerName(selectorName.UTF8String);
        if (![folder respondsToSelector:selector]) {
            continue;
        }
        id value = [folder performSelector:selector];
        if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
            return value;
        }
    }
    return nil;
}

static BOOL APLFolderIsLocked(NSString *folderID) {
    if (folderID.length == 0) {
        return NO;
    }
    return APLBoolInDomain(APLReadSettingsFile(), APLKeyForFolder(folderID), NO);
}

/// The pane's 后台锁定时机, read the way an app reads it: 0 asks every time,
/// a positive number is the grace after a Face ID, -1 lasts until the device
/// locks. A device lock ends the grace in every case.
static BOOL APLFolderGraceHolds(NSString *folderID, NSDictionary *domain) {
    id stored = domain[APLKeyForFolderUnlock(folderID)];
    if (![stored respondsToSelector:@selector(unsignedLongLongValue)]) {
        return NO;
    }
    uint64_t unlockedAt = [stored unsignedLongLongValue];
    if (unlockedAt == 0) {
        return NO;
    }
    if (APLDeviceLockStamp() > unlockedAt) {
        return NO;
    }
    NSInteger delay = APLIntegerInDomain(domain, APLKeyForLockDelay(), 0);
    if (delay == 0) {
        return NO;
    }
    if (delay < 0) {
        return YES;
    }
    return (uint64_t)[NSDate date].timeIntervalSince1970 < unlockedAt + (uint64_t)delay;
}

static void HookedOpenFolder(id self, SEL _cmd, id folderIcon, id location, BOOL animated, id completion) {
    NSDictionary *domain = APLReadSettingsFile();
    BOOL enabled = domain != nil ? APLBoolInDomain(domain, APLKeyForEnabled(), YES) : YES;
    NSString *folderID = APLFolderIdentifierForIconView(folderIcon);
    if (!enabled || !APLFolderIsLocked(folderID)) {
        OriginalOpenFolder(self, _cmd, folderIcon, location, animated, completion);
        return;
    }
    if (APLFolderGraceHolds(folderID, domain)) {
        // Opened a moment ago, inside the wait the pane set: no prompt.
        OriginalOpenFolder(self, _cmd, folderIcon, location, animated, completion);
        return;
    }
    // Face ID first: a refused answer leaves the folder shut.
    APLAskForVerification(@"打开锁定的文件夹", ^(BOOL granted) {
        if (!granted) {
            os_log(TweakLog(), "folder stayed shut");
            return;
        }
        APLWriteLockValue(APLKeyForFolderUnlock(folderID),
                          @((uint64_t)[NSDate date].timeIntervalSince1970));
        // The answer arrives on a background queue, and opening a folder builds
        // views: back to the main queue first.
        dispatch_async(dispatch_get_main_queue(), ^{
            OriginalOpenFolder(self, _cmd, folderIcon, location, animated, completion);
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
