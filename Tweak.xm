
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import "MediaManager.h"

#pragma mark - Configuration

static const CGFloat kVCamButtonSize = 52.0;
static const CGFloat kVCamMargin = 10.0;

#pragma mark - Global State

static BOOL g_vcamEnabled = NO;

static UIWindow *g_overlayWindow = nil;
static UIViewController *g_overlayController = nil;

static UIButton *g_floatButton = nil;
static id g_pickerDelegate = nil;

static NSMutableArray *g_observers = nil;

#pragma mark - Function Declarations

static void VCamCreateOverlay(void);
static void VCamUpdateButton(void);
static void VCamClampButton(void);
static void VCamShowMenu(void);
static void VCamSetEnabled(BOOL enabled);

#pragma mark - Floating Button

@interface VCamFloatButton : UIButton

- (void)handlePan:(UIPanGestureRecognizer *)gesture;
- (void)handleTap:(UITapGestureRecognizer *)gesture;

@end

#pragma mark - Passthrough Window

@interface VCamPassthroughWindow : UIWindow

@property (nonatomic, weak) UIButton *vcamButton;

@end

@implementation VCamPassthroughWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {

    if (self.hidden || self.alpha < 0.01 || !self.userInteractionEnabled) {
        return nil;
    }

    UIView *hitView = [super hitTest:point withEvent:event];

    if (!hitView) {
        return nil;
    }

    // Si hay un menú o selector abierto, la ventana
    // puede recibir los toques de toda la interfaz modal.
    if (self.rootViewController.presentedViewController) {
        return hitView;
    }

    UIButton *button = self.vcamButton;

    if (!button || button.hidden || button.alpha < 0.01) {
        return nil;
    }

    // Solo el botón flotante recibe los toques.
    if (hitView == button || [hitView isDescendantOfView:button]) {
        return hitView;
    }

    // Todo lo demás pasa a la aplicación inferior.
    return nil;
}

@end

#pragma mark - Button Implementation

@implementation VCamFloatButton

- (void)handlePan:(UIPanGestureRecognizer *)gesture {

    UIView *container = self.superview;

    if (!container) {
        return;
    }

    CGPoint translation = [gesture translationInView:container];

    CGPoint center = self.center;

    center.x += translation.x;
    center.y += translation.y;

    CGFloat halfWidth = CGRectGetWidth(self.bounds) / 2.0;
    CGFloat halfHeight = CGRectGetHeight(self.bounds) / 2.0;

    CGFloat minX = halfWidth + kVCamMargin;
    CGFloat maxX = CGRectGetWidth(container.bounds) - halfWidth - kVCamMargin;

    CGFloat minY = halfHeight + kVCamMargin;
    CGFloat maxY = CGRectGetHeight(container.bounds) - halfHeight - kVCamMargin;

    center.x = MAX(minX, MIN(center.x, maxX));
    center.y = MAX(minY, MIN(center.y, maxY));

    self.center = center;

    [gesture setTranslation:CGPointZero inView:container];

    if (gesture.state == UIGestureRecognizerStateEnded ||
        gesture.state == UIGestureRecognizerStateCancelled) {

        CGFloat targetX;

        if (center.x < CGRectGetMidX(container.bounds)) {
            targetX = minX;
        } else {
            targetX = maxX;
        }

        [UIView animateWithDuration:0.22
                              delay:0
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{

            self.center = CGPointMake(targetX, center.y);

        } completion:nil];
    }
}

- (void)handleTap:(UITapGestureRecognizer *)gesture {

    if (gesture.state != UIGestureRecognizerStateEnded) {
        return;
    }

    VCamShowMenu();
}

@end

#pragma mark - Button Appearance

static void VCamUpdateButton(void) {

    if (!g_floatButton) {
        return;
    }

    UIColor *color;

    if (g_vcamEnabled) {

        color = [UIColor colorWithRed:0.12
                                green:0.68
                                 blue:0.36
                                alpha:0.96];

    } else {

        color = [UIColor colorWithRed:0.22
                                green:0.23
                                 blue:0.27
                                alpha:0.96];
    }

    g_floatButton.backgroundColor = color;

    [g_floatButton setTitle:@"📷"
                   forState:UIControlStateNormal];

    g_floatButton.accessibilityLabel =
        g_vcamEnabled ? @"VCam Pro activado" : @"VCam Pro desactivado";
}

#pragma mark - Button Position

static void VCamClampButton(void) {

    if (!g_floatButton || !g_floatButton.superview) {
        return;
    }

    UIView *container = g_floatButton.superview;

    CGFloat halfWidth = CGRectGetWidth(g_floatButton.bounds) / 2.0;
    CGFloat halfHeight = CGRectGetHeight(g_floatButton.bounds) / 2.0;

    CGFloat minX = halfWidth + kVCamMargin;
    CGFloat maxX = CGRectGetWidth(container.bounds) - halfWidth - kVCamMargin;

    CGFloat minY = halfHeight + kVCamMargin;
    CGFloat maxY = CGRectGetHeight(container.bounds) - halfHeight - kVCamMargin;

    CGPoint center = g_floatButton.center;

    center.x = MAX(minX, MIN(center.x, maxX));
    center.y = MAX(minY, MIN(center.y, maxY));

    g_floatButton.center = center;
}

#pragma mark - Video Picker Delegate

@interface VCamImagePickerDelegate : NSObject
    <UINavigationControllerDelegate, UIImagePickerControllerDelegate>
@end

@implementation VCamImagePickerDelegate

- (void)imagePickerController:(UIImagePickerController *)picker
didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {

    NSURL *sourceURL = info[UIImagePickerControllerMediaURL];

    if (!sourceURL) {

        [picker dismissViewControllerAnimated:YES completion:nil];

        return;
    }

    NSURL *destinationURL = [NSURL fileURLWithPath:
        [NSTemporaryDirectory() stringByAppendingPathComponent:@"vcam_input.mp4"]];

    NSFileManager *fileManager = [NSFileManager defaultManager];

    NSError *error = nil;

    [fileManager removeItemAtURL:destinationURL error:nil];

    BOOL copied = [fileManager copyItemAtURL:sourceURL
                                      toURL:destinationURL
                                      error:&error];

    if (!copied) {

        NSLog(@"[VCam Pro] Error copiando vídeo: %@", error);

        [picker dismissViewControllerAnimated:YES completion:nil];

        return;
    }

    [picker dismissViewControllerAnimated:YES completion:^{

        [[MediaManager sharedManager] loadMediaFromURL:destinationURL];

        VCamSetEnabled(YES);

        NSLog(@"[VCam Pro] Vídeo seleccionado correctamente");

    }];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {

    [picker dismissViewControllerAnimated:YES completion:nil];
}

@end

#pragma mark - Enable / Disable

static void VCamSetEnabled(BOOL enabled) {

    g_vcamEnabled = enabled;

    MediaManager *manager = [MediaManager sharedManager];

    if (enabled) {

        [manager start];

    } else {

        [manager stop];
    }

    VCamUpdateButton();

    NSLog(@"[VCam Pro] Estado: %@", enabled ? @"ON" : @"OFF");
}

#pragma mark - Menu

static void VCamShowMenu(void) {

    if (!g_overlayController ||
        !g_overlayWindow ||
        g_overlayWindow.hidden ||
        g_overlayController.presentedViewController) {

        return;
    }

    UIAlertController *alert = [
        UIAlertController alertControllerWithTitle:@"VCam Pro"
        message:g_vcamEnabled
            ? @"Cámara virtual activada"
            : @"Cámara virtual desactivada"
        preferredStyle:UIAlertControllerStyleActionSheet
    ];


    [alert addAction:[
        UIAlertAction actionWithTitle:@"Seleccionar vídeo"
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) {

            if (![UIImagePickerController
                isSourceTypeAvailable:UIImagePickerControllerSourceTypePhotoLibrary]) {

                return;
            }

            UIImagePickerController *picker =
                [[UIImagePickerController alloc] init];

            picker.sourceType =
                UIImagePickerControllerSourceTypePhotoLibrary;

            picker.mediaTypes = @[@"public.movie"];

            picker.videoQuality =
                UIImagePickerControllerQualityTypeHigh;

            picker.delegate = g_pickerDelegate;

            [g_overlayController presentViewController:picker
                                               animated:YES
                                             completion:nil];
        }]
    ];

    [alert addAction:[
        UIAlertAction actionWithTitle:
            g_vcamEnabled ? @"Desactivar cámara virtual" : @"Activar cámara virtual"
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) {

            VCamSetEnabled(!g_vcamEnabled);
        }]
    ];

    [alert addAction:[
        UIAlertAction actionWithTitle:@"Cancelar"
        style:UIAlertActionStyleCancel
        handler:nil]
    ];

    UIPopoverPresentationController *popover =
        alert.popoverPresentationController;

    if (popover && g_floatButton) {

        popover.sourceView = g_floatButton;
        popover.sourceRect = g_floatButton.bounds;
    }

    [g_overlayController presentViewController:alert
                                       animated:YES
                                     completion:nil];
}

#pragma mark - Window Scene

static UIWindowScene *VCamGetActiveScene(void) {

    if (@available(iOS 13.0, *)) {

        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {

            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }

            if (scene.activationState == UISceneActivationStateForegroundActive) {

                return (UIWindowScene *)scene;
            }
        }
    }

    return nil;
}

#pragma mark - Create Overlay

static void VCamCreateOverlay(void) {

    if (![NSThread isMainThread]) {

        dispatch_async(dispatch_get_main_queue(), ^{
            VCamCreateOverlay();
        });

        return;
    }

    UIApplication *application = [UIApplication sharedApplication];

    if (application.applicationState != UIApplicationStateActive) {
        return;
    }

    if (!application.protectedDataAvailable) {
        return;
    }

    if (g_overlayWindow && g_floatButton) {

        g_overlayWindow.hidden = NO;

        VCamClampButton();

        return;
    }

    UIWindowScene *scene = VCamGetActiveScene();

    VCamPassthroughWindow *window = nil;

    if (@available(iOS 13.0, *)) {

        if (scene) {

            window = [[VCamPassthroughWindow alloc]
                initWithWindowScene:scene];
        }
    }

    if (!window) {

        window = [[VCamPassthroughWindow alloc]
            initWithFrame:[UIScreen mainScreen].bounds];
    }

    window.windowLevel = UIWindowLevelAlert - 1;
    window.backgroundColor = UIColor.clearColor;
    window.opaque = NO;
    window.userInteractionEnabled = YES;

    UIViewController *rootController = [[UIViewController alloc] init];

    rootController.view.backgroundColor = UIColor.clearColor;

    rootController.view.frame = window.bounds;

    rootController.view.autoresizingMask =
        UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;

    VCamFloatButton *button =
        [VCamFloatButton buttonWithType:UIButtonTypeSystem];

    button.frame = CGRectMake(
        CGRectGetWidth(window.bounds) - kVCamButtonSize - 15.0,
        130.0,
        kVCamButtonSize,
        kVCamButtonSize
    );

    button.layer.cornerRadius = kVCamButtonSize / 2.0;
    button.layer.masksToBounds = NO;

    button.layer.shadowColor = UIColor.blackColor.CGColor;
    button.layer.shadowOffset = CGSizeMake(0, 3);
    button.layer.shadowOpacity = 0.28;
    button.layer.shadowRadius = 5.0;

    button.titleLabel.font = [UIFont systemFontOfSize:25.0];

    button.tintColor = UIColor.whiteColor;

    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc]
            initWithTarget:button
            action:@selector(handlePan:)];

    pan.maximumNumberOfTouches = 1;

    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc]
            initWithTarget:button
            action:@selector(handleTap:)];

    [tap requireGestureRecognizerToFail:pan];

    [button addGestureRecognizer:pan];
    [button addGestureRecognizer:tap];

    [rootController.view addSubview:button];

    window.rootViewController = rootController;
    window.vcamButton = button;

    g_overlayWindow = window;
    g_overlayController = rootController;
    g_floatButton = button;

    VCamUpdateButton();
    VCamClampButton();

    window.hidden = NO;

    NSLog(@"[VCam Pro] Overlay creado en proceso: %@",
        [[NSBundle mainBundle] bundleIdentifier]);
}

#pragma mark - Lifecycle Notifications

static void VCamRegisterNotifications(void) {

    if (g_observers) {
        return;
    }

    g_observers = [NSMutableArray array];

    NSNotificationCenter *center =
        [NSNotificationCenter defaultCenter];

    id activeObserver = [center
        addObserverForName:UIApplicationDidBecomeActiveNotification
        object:nil
        queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *notification) {

            VCamCreateOverlay();
        }];

    [g_observers addObject:activeObserver];

    id resignObserver = [center
        addObserverForName:UIApplicationWillResignActiveNotification
        object:nil
        queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *notification) {

            g_overlayWindow.hidden = YES;
        }];

    [g_observers addObject:resignObserver];

    id protectedObserver = [center
        addObserverForName:UIApplicationProtectedDataWillBecomeUnavailable
        object:nil
        queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *notification) {

            g_overlayWindow.hidden = YES;
        }];

    [g_observers addObject:protectedObserver];

    id unlockedObserver = [center
        addObserverForName:UIApplicationProtectedDataDidBecomeAvailable
        object:nil
        queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *notification) {

            VCamCreateOverlay();
        }];

    [g_observers addObject:unlockedObserver];

    id orientationObserver = [center
        addObserverForName:UIDeviceOrientationDidChangeNotification
        object:nil
        queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *notification) {

            VCamClampButton();
        }];

    [g_observers addObject:orientationObserver];
}

#pragma mark - Constructor

%ctor {

    @autoreleasepool {

        g_pickerDelegate = [[VCamImagePickerDelegate alloc] init];

        dispatch_async(dispatch_get_main_queue(), ^{

            VCamRegisterNotifications();

            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                dispatch_get_main_queue(),
                ^{

                    VCamCreateOverlay();
                }
            );
        });
    }
}
