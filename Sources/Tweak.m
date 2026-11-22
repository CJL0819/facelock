// SPDX-License-Identifier: MIT
//
// The tweak loads into every app process (the package's filter names the
// UIApplication class, so an app is any process that has one). At launch it
// reads the package's preferences domain: if this app is protected, a window
// above the app's own asks for Face ID before anything else is usable, and
// the app is locked again whenever it goes to the background.

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

#pragma mark - The lock screen

// The window that sits above the app until Face ID has passed.
@interface APLLockViewController : UIViewController
@property (nonatomic, copy) NSString *appName;
@property (nonatomic, copy) void (^onUnlocked)(void);
- (void)authenticate;
- (void)setStatusText:(NSString *)text;
@end

static NSString *sBundleID;
static NSString *sAppName;
static BOOL sEnabled;
static BOOL sProtected;
static BOOL sLocked;
static BOOL sPrompted;
static BOOL sPrepared;
static UIWindow *sLockWindow;
static APLLockViewController *sLockController;

static UIColor *APLAccentColor(void) {
    return [UIColor colorWithRed:0.0 green:0.478 blue:1.0 alpha:1.0];
}

@implementation APLLockViewController {
    UILabel *_statusLabel;
    UIButton *_unlockButton;
    LAContext *_context;
    BOOL _authenticating;
    BOOL _didPrompt;
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
    [_unlockButton setTitle:@"解锁" forState:UIControlStateNormal];
    [_unlockButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _unlockButton.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    _unlockButton.backgroundColor = APLAccentColor();
    _unlockButton.layer.cornerRadius = 23.0;
    _unlockButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_unlockButton.widthAnchor constraintEqualToConstant:196.0].active = YES;
    [_unlockButton.heightAnchor constraintEqualToConstant:46.0].active = YES;
    [_unlockButton addTarget:self action:@selector(unlockTapped:) forControlEvents:UIControlEventTouchUpInside];

    _statusLabel = [UILabel new];
    _statusLabel.font = [UIFont systemFontOfSize:13.0];
    _statusLabel.textColor = [UIColor colorWithRed:1.0 green:0.42 blue:0.42 alpha:1.0];
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.numberOfLines = 0;
    _statusLabel.hidden = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[iconView, titleLabel, nameLabel, hintLabel, _unlockButton, _statusLabel]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 12.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [stack setCustomSpacing:24.0 afterView:hintLabel];
    [stack setCustomSpacing:16.0 afterView:_unlockButton];
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
    [self authenticate];
}

- (void)setStatusText:(NSString *)text {
    _statusLabel.text = text;
    _statusLabel.hidden = text.length == 0;
}

- (void)authenticate {
    if (_authenticating) {
        return;
    }
    _authenticating = YES;

    LAContext *context = [[LAContext alloc] init];
    _context = context;
    context.localizedFallbackTitle = @"使用密码";
    context.localizedCancelTitle = @"取消";

    NSError *availability = nil;
    if (![context canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:&availability]) {
        _authenticating = NO;
        _context = nil;
        os_log(TweakLog(), "canEvaluatePolicy failed: %{public}s", availability.localizedDescription.UTF8String ?: "(none)");
        [self setStatusText:availability.localizedDescription.length ? availability.localizedDescription : @"面容 ID 不可用，请先录入面容并设置密码"];
        return;
    }

    NSString *reason = [NSString stringWithFormat:@"解锁“%@”", self.appName.length ? self.appName : @"此 App"];
    __weak typeof(self) weakSelf = self;
    [context evaluatePolicy:LAPolicyDeviceOwnerAuthentication
            localizedReason:reason
                      reply:^(BOOL success, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            strongSelf->_authenticating = NO;
            strongSelf->_context = nil;
            os_log(TweakLog(), "evaluatePolicy success=%d error=%{public}s",
                   (int)success, error.localizedDescription.UTF8String ?: "(none)");
            if (success) {
                [strongSelf setStatusText:nil];
                [strongSelf->_unlockButton setTitle:@"解锁" forState:UIControlStateNormal];
                if (strongSelf.onUnlocked) {
                    strongSelf.onUnlocked();
                }
            } else {
                [strongSelf->_unlockButton setTitle:@"重试" forState:UIControlStateNormal];
                NSString *detail = error.localizedDescription.length ? error.localizedDescription : @"请重试";
                [strongSelf setStatusText:[NSString stringWithFormat:@"未通过验证：%@", detail]];
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
    if (fallback == nil) {
        for (UIScene *scene in application.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                fallback = (UIWindowScene *)scene;
                break;
            }
        }
    }
    return fallback;
}

// A window made after iOS 13 shows only once it belongs to a scene; the app's
// scene may not be connected yet when this runs at launch.
static void APLPlaceLockWindow(void) {
    if (sLockWindow == nil) {
        return;
    }
    UIWindowScene *scene = APLForegroundWindowScene();
    if (scene == nil) {
        return;
    }
    if (sLockWindow.windowScene != scene) {
        sLockWindow.windowScene = scene;
    }
    sLockWindow.frame = scene.coordinateSpace.bounds;
    sLockWindow.hidden = NO;
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
        sLockWindow.windowLevel = UIWindowLevelAlert + 100.0;
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
    APLPlaceLockWindow();
    if (sLockWindow.windowScene == nil) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            APLPlaceLockWindow();
        });
    }
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
        name = bundle.bundleIdentifier;
    }
    return name.length ? name : @"此 App";
}

// cfprefsd keeps this device's domains in the bootstrap's own
// ~/Library/Preferences, so that file can be read without a cfprefsd round
// trip. On the launch path the round trip is what hangs a sandboxed app, and
// the lock has to be up before the app draws anything.
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
            os_log(TweakLog(), "settings file found at candidate %lu", (unsigned long)index);
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

static void APLApplyState(BOOL enabled, BOOL protected) {
    if (sBundleID.length == 0) {
        return;
    }
    sEnabled = enabled;
    sProtected = protected;
    os_log(TweakLog(), "state enabled=%d protected=%d", (int)enabled, (int)protected);

    if (!(enabled && protected)) {
        if (sLocked) {
            sLocked = NO;
            sPrompted = NO;
            APLHideLockWindow();
        }
        return;
    }
    if (!sLocked) {
        // Protection was turned on while the app was running: lock it now.
        sLocked = YES;
        sPrompted = NO;
        APLShowLock();
        APLPromptIfNeeded();
    } else if (sLockWindow.hidden) {
        APLShowLock();
    }
}

// The file is the only source the tweak trusts: a sandboxed app's cfprefsd
// read of another domain came back empty on this device, and it would have
// unlocked the app the file had just locked.
static void APLApplyStateFromFile(void) {
    if (sBundleID.length == 0) {
        return;
    }
    NSDictionary *domain = APLReadSettingsFile();
    if (domain == nil) {
        os_log(TweakLog(), "settings file unreadable");
        return;
    }
    APLApplyState(APLBoolInDomain(domain, @"enabled", YES),
                  APLBoolInDomain(domain, APLKeyForBundle(sBundleID), NO));
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

static void APLStartListeningForChanges(void) {
    static int token;
    notify_register_dispatch(APLChangedNotificationName().UTF8String, &token, dispatch_get_main_queue(), ^(int __unused note) {
        os_log(TweakLog(), "settings changed, reloading");
        static const double delays[] = {0.5, 2.0};
        APLReapplyAfterChanges(delays, sizeof(delays) / sizeof(delays[0]));
    });
}

static void APLInstallObservers(void) {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];

    [center addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *__unused note) {
        if (!sEnabled || !sProtected || !sLocked) {
            return;
        }
        APLShowLock();
        sPrompted = NO;
        APLPromptIfNeeded();
    }];

    // Lock again as the app leaves, so the app switcher shows the lock screen
    // rather than the app's content.
    [center addObserverForName:UIApplicationDidEnterBackgroundNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *__unused note) {
        if (!sEnabled || !sProtected) {
            return;
        }
        sLocked = YES;
        sPrompted = NO;
        APLShowLock();
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

#pragma mark - Hooking the app's launch

static void APLPrepareForHost(void) {
    if (sPrepared) {
        return;
    }
    sPrepared = YES;

    NSString *bundleID = [NSBundle mainBundle].bundleIdentifier;
    if (bundleID.length == 0 || [bundleID isEqualToString:@"com.apple.springboard"]) {
        return;  // Not an app the pane could list.
    }
    sBundleID = bundleID;
    sAppName = APLHostDisplayName();

    APLApplyStateFromFile();

    // The window's scene and the change listener come up once the app's run
    // loop is going, and the settings file is read once more in case cfprefsd
    // flushed the pane's last write only after launch.
    dispatch_async(dispatch_get_main_queue(), ^{
        APLInstallObservers();
        APLStartListeningForChanges();
        static const double delays[] = {0.8};
        APLReapplyAfterChanges(delays, sizeof(delays) / sizeof(delays[0]));
    });
}

static void (*OriginalRun)(id self, SEL _cmd);

// -[UIApplication _run] is where UIApplicationMain settles before the app's
// own launch callbacks, so the lock is up before the app draws anything.
static void HookedRun(id self, SEL _cmd) {
    APLPrepareForHost();
    if (OriginalRun != NULL) {
        OriginalRun(self, _cmd);
    }
}

__attribute__((constructor)) static void TweakInitialize(void) {
    // Apelin's confirm_loaded looks for this exact marker and build id under
    // the package id's subsystem. Keep the line, and keep it public.
    os_log(TweakLog(), "ApelinLoaded %{public}s in %{public}s", APELIN_BUILD_ID, getprogname());

    Class applicationClass = objc_getClass("UIApplication");
    if (applicationClass == Nil) {
        return;  // A process without UIKit, whatever the filter said.
    }
    MSHookMessageEx(applicationClass, sel_registerName("_run"), (IMP)HookedRun, (IMP *)&OriginalRun);
}
