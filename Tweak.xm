
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
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

static const void *kVCamDelegateProxyKey = &kVCamDelegateProxyKey;

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

@implementation VCamFloatButton

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    UIView *container = self.superview;
    if (!container) return;

    CGPoint translation = [gesture translationInView:container];
    CGPoint center = self.center;

    center.x += translation.x;
    center.y += translation.y;

    CGFloat halfW = CGRectGetWidth(self.bounds) / 2.0;
    CGFloat halfH = CGRectGetHeight(self.bounds) / 2.0;

    CGFloat minX = halfW + kVCamMargin;
    CGFloat maxX = CGRectGetWidth(container.bounds) - halfW - kVCamMargin;
    CGFloat minY = halfH + kVCamMargin;
    CGFloat maxY = CGRectGetHeight(container.bounds) - halfH - kVCamMargin;

    center.x = MAX(minX, MIN(center.x, maxX));
    center.y = MAX(minY, MIN(center.y, maxY));

    self.center = center;
    [gesture setTranslation:CGPointZero inView:container];

    if (gesture.state == UIGestureRecognizerStateEnded ||
        gesture.state == UIGestureRecognizerStateCancelled) {

        CGFloat targetX = center.x < CGRectGetMidX(container.bounds)
            ? minX : maxX;

        [UIView animateWithDuration:0.22
                              delay:0
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            self.center = CGPointMake(targetX, center.y);
        } completion:nil];
    }
}

- (void)handleTap:(UITapGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateEnded) {
        VCamShowMenu();
    }
}

@end

#pragma mark - Passthrough Window

@interface VCamPassthroughWindow : UIWindow
@property (nonatomic, weak) UIButton *vcamButton;
@end

@implementation VCamPassthroughWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || self.alpha < 0.01 ||
        !self.userInteractionEnabled) {
        return nil;
    }

    UIView *hitView = [super hitTest:point withEvent:event];
    if (!hitView) return nil;

    if (self.rootViewController.presentedViewController) {
        return hitView;
    }

    UIButton *button = self.vcamButton;
    if (!button || button.hidden || button.alpha < 0.01) {
        return nil;
    }

    if (hitView == button || [hitView isDescendantOfView:button]) {
        return hitView;
    }

    return nil;
}

@end

#pragma mark - Video Delegate Proxy

/*
 * Intermediario del delegado de AVCaptureVideoDataOutput.
 * Entrega el frame virtual al delegado original cuando VCam está activa.
 */

@interface VCamSampleBufferDelegateProxy : NSObject
<AVCaptureVideoDataOutputSampleBufferDelegate>

@property (nonatomic, weak) id<AVCaptureVideoDataOutputSampleBufferDelegate> originalDelegate;

- (instancetype)initWithDelegate:
    (id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate;

@end

@implementation VCamSampleBufferDelegateProxy

- (instancetype)initWithDelegate:
    (id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate {

    self = [super init];
    if (self) {
        _originalDelegate = delegate;
    }
    return self;
}

- (BOOL)respondsToSelector:(SEL)selector {
    if ([super respondsToSelector:selector]) return YES;
    return [self.originalDelegate respondsToSelector:selector];
}

- (id)forwardingTargetForSelector:(SEL)selector {
    if ([self.originalDelegate respondsToSelector:selector]) {
        return self.originalDelegate;
    }
    return [super forwardingTargetForSelector:selector];
}

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {

    id<AVCaptureVideoDataOutputSampleBufferDelegate> delegate =
        self.originalDelegate;

    if (!delegate) return;

    if (!g_vcamEnabled) {
        [delegate captureOutput:output
         didOutputSampleBuffer:sampleBuffer
                fromConnection:connection];
        return;
    }

    CMSampleBufferRef virtualFrame =
        [[MediaManager sharedManager] nextVideoFrame];

    if (!virtualFrame) {
        [delegate captureOutput:output
         didOutputSampleBuffer:sampleBuffer
                fromConnection:connection];
        return;
    }

    [delegate captureOutput:output
     didOutputSampleBuffer:virtualFrame
            fromConnection:connection];

    CFRelease(virtualFrame);
}

- (void)captureOutput:(AVCaptureOutput *)output
 didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {

    id<AVCaptureVideoDataOutputSampleBufferDelegate> delegate =
        self.originalDelegate;

    if ([delegate respondsToSelector:
         @selector(captureOutput:didDropSampleBuffer:fromConnection:)]) {

        [delegate captureOutput:output
          didDropSampleBuffer:sampleBuffer
                fromConnection:connection];
    }
}

@end

#pragma mark - AVCaptureVideoDataOutput Hook

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:
    (id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate
                           queue:(dispatch_queue_t)queue {

    if (!delegate) {
        objc_setAssociatedObject(
            self,
            kVCamDelegateProxyKey,
            nil,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC
        );

        %orig(nil, queue);
        return;
    }

    VCamSampleBufferDelegateProxy *proxy =
        [[VCamSampleBufferDelegateProxy alloc] initWithDelegate:delegate];

    /*
     * Conservamos el proxy asociado a la salida para que no desaparezca
     * mientras AVFoundation lo utiliza.
     */
    objc_setAssociatedObject(
        self,
        kVCamDelegateProxyKey,
        proxy,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC
    );

    %orig(proxy, queue);
}

%end

#pragma mark - Button Appearance

static void VCamUpdateButton(void) {
    if (!g_floatButton) return;

    g_floatButton.backgroundColor = g_vcamEnabled
        ? [UIColor colorWithRed:0.12 green:0.68 blue:0.36 alpha:0.96]
        : [UIColor colorWithRed:0.22 green:0.23 blue:0.27 alpha:0.96];

    [g_floatButton setTitle:@"📷" forState:UIControlStateNormal];

    g_floatButton.accessibilityLabel = g_vcamEnabled
        ? @"VCam Pro activado"
        : @"VCam Pro desactivado";
}

#pragma mark - Button Position

static void VCamClampButton(void) {
    if (!g_floatButton || !g_floatButton.superview) return;

    UIView *container = g_floatButton.superview;

    CGFloat halfW = CGRectGetWidth(g_floatButton.bounds) / 2.0;
    CGFloat halfH = CGRectGetHeight(g_floatButton.bounds) / 2.0;

    CGFloat minX = halfW + kVCamMargin;
    CGFloat maxX = CGRectGetWidth(container.bounds) - halfW - kVCamMargin;
    CGFloat minY = halfH + kVCamMargin;
    CGFloat maxY = CGRectGetHeight(container.bounds) - halfH - kVCamMargin;

    CGPoint center = g_floatButton.center;

    center.x = MAX(minX, MIN(center.x, maxX));
    center.y = MAX(minY, MIN(center.y, maxY));

    g_floatButton.center = center;
}

#pragma mark - Video Picker

@interface VCamImagePickerDelegate : NSObject
<UINavigationControllerDelegate, UIImagePickerControllerDelegate>
@end

@implementation VCamImagePickerDelegate

- (void)imagePickerController:(UIImagePickerController *)picker
didFinishPickingMediaWithInfo:
    (NSDictionary<UIImagePickerControllerInfoKey,id> *)info {

    NSURL *sourceURL = info[UIImagePickerControllerMediaURL];

    if (!sourceURL) {
        [picker dismissViewControllerAnimated:YES completion:nil];
        return;
    }

    NSURL *destinationURL = [NSURL fileURLWithPath:
        [NSTemporaryDirectory() stringByAppendingPathComponent:
            @"vcam_input.mp4"]];

    NSFileManager *fileManager = [NSFileManager defaultManager];

    [fileManager removeItemAtURL:destinationURL error:nil];

    NSError *error = nil;

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

        /*
         * MediaManager carga el archivo en su cola interna.
         * La activación se realiza después de solicitar la carga.
         */
        VCamSetEnabled(YES);
    }];
}

- (void)imagePickerControllerDidCancel:
    (UIImagePickerController *)picker {

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

    NSLog(@"[VCam Pro] Estado: %@",
          enabled ? @"ON" : @"OFF");
}

#pragma mark - Menu

static void VCamShowMenu(void) {
    if (!g_overlayController ||
        !g_overlayWindow ||
        g_overlayWindow.hidden ||
        g_overlayController.presentedViewController) {
        return;
    }

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"VCam Pro"
                                            message:g_vcamEnabled
                ? @"Cámara virtual activada"
                : @"Cámara virtual desactivada"
                                     preferredStyle:
                UIAlertControllerStyleActionSheet];

    [alert addAction:
        [UIAlertAction actionWithTitle:@"Seleccionar vídeo"
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *action) {

        if (![UIImagePickerController
              isSourceTypeAvailable:
              UIImagePickerControllerSourceTypePhotoLibrary]) {
            return;
        }

        UIImagePickerController *picker =
            [[UIImagePickerController alloc] init];

        picker.sourceType =
            UIImagePickerControllerSourceTypePhotoLibrary;

        picker.mediaTypes = @[@"public.movie"];
        picker.videoQuality = UIImagePickerControllerQualityTypeHigh;
        picker.delegate = g_pickerDelegate;

        [g_overlayController presentViewController:picker
                                           animated:YES
                                         completion:nil];
    }]];

    [alert addAction:
        [UIAlertAction actionWithTitle:
            g_vcamEnabled ? @"Desactivar cámara virtual"
                          : @"Activar cámara virtual"
                         style:UIAlertActionStyleDefault
                       handler:^(UIAlertAction *action) {
        VCamSetEnabled(!g_vcamEnabled);
    }]];

    [alert addAction:
        [UIAlertAction actionWithTitle:@"Cancelar"
                                 style:UIAlertActionStyleCancel
                               handler:nil]];

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

#pragma mark - Active Scene

static UIWindowScene *VCamGetActiveScene(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in
             [UIApplication sharedApplication].connectedScenes) {

            if (![scene isKindOfClass:[UIWindowScene class]]) continue;

            if (scene.activationState ==
                UISceneActivationStateForegroundActive) {
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

    UIApplication *application =
        [UIApplication sharedApplication];

    if (application.applicationState != UIApplicationStateActive ||
        !application.protectedDataAvailable) {
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

    UIViewController *rootController =
        [[UIViewController alloc] init];

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

#pragma mark - Lifecycle

static void VCamRegisterNotifications(void) {
    if (g_observers) return;

    g_observers = [NSMutableArray array];

    NSNotificationCenter *center =
        [NSNotificationCenter defaultCenter];

    id activeObserver =
        [center addObserverForName:
            UIApplicationDidBecomeActiveNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *notification) {
        VCamCreateOverlay();
    }];

    [g_observers addObject:activeObserver];

    id resignObserver =
        [center addObserverForName:
            UIApplicationWillResignActiveNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *notification) {
        g_overlayWindow.hidden = YES;
    }];

    [g_observers addObject:resignObserver];

    id protectedObserver =
        [center addObserverForName:
            UIApplicationProtectedDataWillBecomeUnavailable
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *notification) {
        g_overlayWindow.hidden = YES;
    }];

    [g_observers addObject:protectedObserver];

    id unlockedObserver =
        [center addObserverForName:
            UIApplicationProtectedDataDidBecomeAvailable
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *notification) {
        VCamCreateOverlay();
    }];

    [g_observers addObject:unlockedObserver];

    id orientationObserver =
        [center addObserverForName:
            UIDeviceOrientationDidChangeNotification
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
        %init;

        g_pickerDelegate = [[VCamImagePickerDelegate alloc] init];

        dispatch_async(dispatch_get_main_queue(), ^{
            VCamRegisterNotifications();

            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW,
                              (int64_t)(1.0 * NSEC_PER_SEC)),
                dispatch_get_main_queue(),
                ^{
                    VCamCreateOverlay();
                }
            );
        });
    }
}
