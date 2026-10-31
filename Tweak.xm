#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <substrate.h>
#import "MediaManager.h"

// ============================================================================
// MARK: - 全局状态
// ============================================================================

@interface VCamPassthroughWindow : UIWindow
@property (nonatomic, weak) UIView *interactiveView;
@end

@implementation VCamPassthroughWindow

// La ventana solamente recibe toques dentro del botón.
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *target = self.interactiveView;

    if (!target || self.hidden || self.alpha < 0.01 ||
        target.hidden || target.alpha < 0.01) {
        return NO;
    }

    CGPoint localPoint = [target convertPoint:point fromView:self];
    return CGRectContainsPoint(target.bounds, localPoint);
}

@end

static void handlePanGesture(UIPanGestureRecognizer *gesture);
static void handleTapGesture(UITapGestureRecognizer *gesture);

@interface VCamFloatButton : UIButton
- (void)handlePan:(UIPanGestureRecognizer *)gesture;
- (void)handleTap:(UITapGestureRecognizer *)gesture;
@end

@implementation VCamFloatButton

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    handlePanGesture(gesture);
}

- (void)handleTap:(UITapGestureRecognizer *)gesture {
    handleTapGesture(gesture);
}

@end

static BOOL g_vcamEnabled = NO;
static VCamPassthroughWindow *g_overlayWindow = nil;
static VCamFloatButton *g_floatButton = nil;

static void setupFloatButton(void) {

    if (g_floatButton && g_overlayWindow) return;

    CGRect screen = [UIScreen mainScreen].bounds;
    CGFloat btnSize = 50;

    g_floatButton = [VCamFloatButton buttonWithType:UIButtonTypeSystem];

    g_floatButton.frame = CGRectMake(
        screen.size.width - btnSize - 15,
        120,
        btnSize,
        btnSize
    );

    g_floatButton.layer.cornerRadius = btnSize / 2.0;
    g_floatButton.layer.shadowColor = UIColor.blackColor.CGColor;
    g_floatButton.layer.shadowOffset = CGSizeMake(0, 2);
    g_floatButton.layer.shadowOpacity = 0.3;
    g_floatButton.layer.shadowRadius = 4;

    g_floatButton.backgroundColor =
        [UIColor colorWithRed:0.4 green:0.4 blue:0.4 alpha:0.95];

    [g_floatButton setTitle:@"📷" forState:UIControlStateNormal];
    g_floatButton.titleLabel.font = [UIFont systemFontOfSize:24];

    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc]
            initWithTarget:g_floatButton
            action:@selector(handlePan:)];

    pan.maximumNumberOfTouches = 1;

    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc]
            initWithTarget:g_floatButton
            action:@selector(handleTap:)];

    [tap requireGestureRecognizerToFail:pan];

    [g_floatButton addGestureRecognizer:pan];
    [g_floatButton addGestureRecognizer:tap];

    // Ventana transparente con passthrough.
    g_overlayWindow =
        [[VCamPassthroughWindow alloc] initWithFrame:screen];

    g_overlayWindow.windowLevel = UIWindowLevelAlert - 1;
    g_overlayWindow.backgroundColor = UIColor.clearColor;
    g_overlayWindow.opaque = NO;
    g_overlayWindow.interactiveView = g_floatButton;

    UIViewController *rootVC = [[UIViewController alloc] init];

    rootVC.view.frame = screen;
    rootVC.view.backgroundColor = UIColor.clearColor;

    [rootVC.view addSubview:g_floatButton];

    g_overlayWindow.rootViewController = rootVC;
    g_overlayWindow.hidden = NO;
}

static void handlePanGesture(UIPanGestureRecognizer *gesture) {

    UIView *button = gesture.view;
    UIView *container = button.superview;

    CGPoint translation = [gesture translationInView:container];

    CGPoint center = button.center;
    center.x += translation.x;
    center.y += translation.y;

    CGFloat halfWidth = CGRectGetWidth(button.bounds) / 2.0;
    CGFloat halfHeight = CGRectGetHeight(button.bounds) / 2.0;

    center.x = MAX(halfWidth + 5,
                   MIN(center.x, CGRectGetWidth(container.bounds) - halfWidth - 5));

    center.y = MAX(halfHeight + 5,
                   MIN(center.y, CGRectGetHeight(container.bounds) - halfHeight - 5));

    button.center = center;

    [gesture setTranslation:CGPointZero inView:container];

    if (gesture.state == UIGestureRecognizerStateEnded) {

        CGFloat x = center.x < CGRectGetMidX(container.bounds)
            ? halfWidth + 5
            : CGRectGetWidth(container.bounds) - halfWidth - 5;

        [UIView animateWithDuration:0.2 animations:^{
            button.center = CGPointMake(x, center.y);
        }];
    }
}

static UIViewController *findTopViewController(void) {
    UIViewController *topVC = nil;
    for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *w in scene.windows) {
                if (w.isKeyWindow) {
                    topVC = w.rootViewController;
                    break;
                }
            }
        }
    }
    while (topVC && topVC.presentedViewController) {
        topVC = topVC.presentedViewController;
    }
    return topVC;
}

@interface VCamImagePickerControllerDelegate : NSObject <UINavigationControllerDelegate, UIImagePickerControllerDelegate>
@end

@implementation VCamImagePickerControllerDelegate

- (void)imagePickerController:(UIImagePickerController *)picker 
        didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
    [picker dismissViewControllerAnimated:YES completion:nil];
    
    NSURL *url = info[UIImagePickerControllerMediaURL];
    if (!url) return;
    
    NSURL *tempURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() 
        stringByAppendingPathComponent:@"vcam_input.mp4"]];
    [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
    [[NSFileManager defaultManager] copyItemAtURL:url toURL:tempURL error:nil];
    
    [[MediaManager sharedManager] loadMediaFromURL:tempURL];
    g_vcamEnabled = YES;
    [[MediaManager sharedManager] start];
    if (g_floatButton) {
        g_floatButton.backgroundColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:0.9];
    }
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

@end

static VCamImagePickerControllerDelegate *g_pickerDelegate = nil;

static void handleTapGesture(UITapGestureRecognizer *gesture) {
    UIViewController *topVC = findTopViewController();
    if (!topVC) return;
    
    UIAlertController *alert = [UIAlertController 
        alertControllerWithTitle:@"VCam" 
        message:g_vcamEnabled ? @"虚拟相机已启用" : @"虚拟相机已关闭"
        preferredStyle:UIAlertControllerStyleActionSheet];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"选择视频" 
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        
        if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeSavedPhotosAlbum]) {
            return;
        }
        UIImagePickerController *picker = [[UIImagePickerController alloc] init];
        picker.sourceType = UIImagePickerControllerSourceTypeSavedPhotosAlbum;
        picker.mediaTypes = @[@"public.movie"];
        picker.delegate = g_pickerDelegate;
        [topVC presentViewController:picker animated:YES completion:nil];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:g_vcamEnabled ? @"关闭虚拟相机" : @"开启虚拟相机" 
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        g_vcamEnabled = !g_vcamEnabled;
        if (g_floatButton) {
            g_floatButton.backgroundColor = g_vcamEnabled 
                ? [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:0.9]
                : [UIColor colorWithRed:0.4 green:0.4 blue:0.4 alpha:0.9];
        }
        if (g_vcamEnabled) {
            [[MediaManager sharedManager] start];
        } else {
            [[MediaManager sharedManager] stop];
        }
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    
    if (alert.popoverPresentationController) {
        alert.popoverPresentationController.sourceView = gesture.view;
        alert.popoverPresentationController.sourceRect = gesture.view.bounds;
    }
    
    [topVC presentViewController:alert animated:YES completion:nil];
}

// ============================================================================
// MARK: - Hook AVCaptureSession / Video Output
// ============================================================================

%group VCamHooks

%hook AVCaptureSession
- (void)startRunning { %orig; }
- (void)stopRunning { %orig; }
%end

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate 
                          queue:(dispatch_queue_t)queue {
    %orig;
}
%end

// Intercept frame delegate callback -> substitute with fake frames
%hook NSObject
- (void)captureOutput:(AVCaptureOutput *)output 
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer 
           fromConnection:(AVCaptureConnection *)connection {
    
    if (g_vcamEnabled && [[MediaManager sharedManager] isRunning]) {
        CMSampleBufferRef fakeFrame = [[MediaManager sharedManager] nextVideoFrame];
        if (fakeFrame) {
            %orig(output, fakeFrame, connection);
            CFRelease(fakeFrame);
            return;
        }
    }
    %orig;
}
%end

%hook AVCapturePhotoOutput
- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings 
                        delegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
    %orig;
}
%end

%hook AVCaptureVideoPreviewLayer
- (void)setSession:(AVCaptureSession *)session {
    %orig;
}
%end

%end // VCamHooks group

// ============================================================================
// MARK: - Constructor
// ============================================================================

%ctor {
    @autoreleasepool {
        g_pickerDelegate = [[VCamImagePickerControllerDelegate alloc] init];
        
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        if (![bundleID isEqualToString:@"com.apple.springboard"]) {
            %init(VCamHooks);
        }
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), 
            dispatch_get_main_queue(), ^{
                @autoreleasepool {
                    setupFloatButton();
                }
            });
    }
}
