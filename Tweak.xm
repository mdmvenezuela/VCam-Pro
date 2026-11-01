#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <arpa/inet.h>
#import <errno.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>
#import <sys/time.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <limits.h>
#import <stdlib.h>
#import <math.h>
#import <string.h>

#import "MediaManager.h"
#import "VCamSharedState.h"

#pragma mark - Constants

static const CGFloat kVCamButtonSize = 52.0;
static const CGFloat kVCamButtonMargin = 12.0;

#pragma mark - Process State

static BOOL g_isSpringBoardProcess = NO;
static dispatch_source_t g_orientationDiagnosticTimer = nil;
static NSInteger g_lastDiagnosticDeviceOrientation = NSIntegerMin;
static NSInteger g_lastDiagnosticInterfaceOrientation = NSIntegerMin;
static NSInteger g_lastClientDeviceOrientation = NSIntegerMin;
static NSInteger g_lastClientInterfaceOrientation = NSIntegerMin;
static CFTimeInterval g_lastClientOrientationDiagnosticTime = 0.0;
static BOOL g_vcamEnabled = NO;
static CGFloat g_vcamZoom = 1.0;
static CGFloat g_vcamOffsetX = 0.0;
static CGFloat g_vcamOffsetY = 0.0;
static NSInteger g_vcamRotationDegrees = 0;
static BOOL g_vcamMirrorEnabled = NO;
static BOOL g_vcamMotionEnabled = NO;
static CGFloat g_vcamButtonX = 0.92;
static CGFloat g_vcamButtonY = 0.24;
static NSInteger g_lastMediaRevision = -1;
static NSInteger g_loadingMediaRevision = -1;
static NSInteger g_failedMediaRevision = -1;
static NSInteger g_mediaLoadAttemptRevision = -1;
static NSUInteger g_mediaLoadAttemptCount = 0;
static dispatch_queue_t g_syncQueue;
static UIWindow *g_overlayWindow = nil;
static UIViewController *g_overlayController = nil;
static UIButton *g_floatButton = nil;
@class VCamAdjustmentPanel;
static VCamAdjustmentPanel *g_adjustmentPanel = nil;
static NSInteger g_adjustmentPreviewRevision = -1;
@class VCamLiveDiagnosticsPanel;
static VCamLiveDiagnosticsPanel *g_liveDiagnosticsPanel = nil;
static id g_pickerDelegate = nil;
static NSMutableArray *g_lifecycleObservers = nil;
static char g_darwinObserverToken;
static const void *kVCamDelegateProxyKey = &kVCamDelegateProxyKey;
static NSUInteger g_vcamVideoCallbackCount = 0;
static NSUInteger g_vcamVideoReplacementCount = 0;
static NSUInteger g_vcamClientConnectionDiagnosticCount = 0;
static NSMutableDictionary<NSString *, NSDictionary *> *g_vcamClientConnectionDiagnostics = nil;
static NSUInteger g_vcamClientOutputAttachDiagnosticCount = 0;
static NSHashTable<CALayer *> *g_previewOverlayLayers = nil;
static CIContext *g_previewCIContext = nil;
static dispatch_source_t g_previewPumpTimer = nil;
static CFTimeInterval g_lastVideoOutputCallbackTime = 0.0;
static const void *kVCamPreviewOverlayKey = &kVCamPreviewOverlayKey;

static void VCamAttachPreviewOverlay(AVCaptureVideoPreviewLayer *previewLayer);
static void VCamUpdatePreviewOverlaysWithSampleBuffer(CMSampleBufferRef sampleBuffer);
static void VCamUpdatePreviewOverlaysWithJPEG(NSData *jpegData);
static void VCamSetPreviewOverlaysVisible(BOOL visible);

static void VCamRefreshFromServer(void);
static void VCamCreateOverlay(void);
static void VCamShowMenu(void);
static void VCamUpdateButton(void);
static BOOL VCamIsEnabled(void);
static void VCamClampButton(void);
static void VCamShowAdjustmentPanel(void);
static void VCamCloseAdjustmentPanel(void);

static BOOL VCamIsEnabled(void) {
    @synchronized ([MediaManager class]) {
        return g_vcamEnabled;
    }
}

static void VCamSetLocalEnabled(BOOL enabled) {
    @synchronized ([MediaManager class]) {
        g_vcamEnabled = enabled;
    }
}

#pragma mark - IPC Client

static int VCamConnectToServer(void) {
    int socketFD = socket(AF_INET, SOCK_STREAM, 0);
    if (socketFD < 0) return -1;

    int noSigPipe = 1;
    setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));

    struct timeval timeout;
    timeout.tv_sec = 120;
    timeout.tv_usec = 0;
    setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_port = htons(47831);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (connect(socketFD, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(socketFD);
        return -1;
    }
    return socketFD;
}

static BOOL VCamSocketSendAll(int socketFD, const void *bytes, size_t length) {
    const uint8_t *cursor = (const uint8_t *)bytes;
    size_t sent = 0;
    while (sent < length) {
        ssize_t amount = send(socketFD, cursor + sent, length - sent, 0);
        if (amount < 0) {
            if (errno == EINTR) continue;
            return NO;
        }
        if (amount == 0) return NO;
        sent += (size_t)amount;
    }
    return YES;
}

static void VCamSendOrientationDiagnosticEvent(NSString *line) {
    if (![line isKindOfClass:[NSString class]] || line.length == 0) return;
    NSString *safeLine = [line copy];

    // Never hold up AVCapture's delegate queue for diagnostic IPC.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *payload = @{@"line": safeLine};
        NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
        if (!body || body.length > 8 * 1024) return;

        int socketFD = VCamConnectToServer();
        if (socketFD < 0) return;

        struct timeval timeout = {1, 0};
        setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));

        NSString *header = [NSString stringWithFormat:
            @"POST /orientation-diagnostic HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n",
            (unsigned long)body.length];
        BOOL sentHeader = VCamSocketSendAll(socketFD, header.UTF8String, header.length);
        BOOL sentBody = sentHeader && VCamSocketSendAll(socketFD, body.bytes, body.length);
        (void)sentBody;
        close(socketFD);
    });
}

static NSData *VCamHTTPGet(NSString *path) {
    int socketFD = VCamConnectToServer();
    if (socketFD < 0) return nil;

    NSString *request = [NSString stringWithFormat:@"GET %@ HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n", path];
    if (!VCamSocketSendAll(socketFD, request.UTF8String, request.length)) {
        close(socketFD);
        return nil;
    }

    NSMutableData *response = [NSMutableData data];
    uint8_t buffer[16 * 1024];
    const NSUInteger maximumResponseSize = 2 * 1024 * 1024;
    while (YES) {
        ssize_t amount = recv(socketFD, buffer, sizeof(buffer), 0);
        if (amount < 0) {
            if (errno == EINTR) continue;
            close(socketFD);
            return nil;
        }
        if (amount == 0) break;
        if (response.length + (NSUInteger)amount > maximumResponseSize) {
            close(socketFD);
            return nil;
        }
        [response appendBytes:buffer length:(NSUInteger)amount];
    }
    close(socketFD);

    NSData *separator = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange range = [response rangeOfData:separator options:0 range:NSMakeRange(0, response.length)];
    if (range.location == NSNotFound) return nil;
    NSData *headerData = [response subdataWithRange:NSMakeRange(0, range.location)];
    NSString *headerText = [[NSString alloc] initWithData:headerData encoding:NSUTF8StringEncoding];
    if (![headerText hasPrefix:@"HTTP/1.1 200"] && ![headerText hasPrefix:@"HTTP/1.0 200"]) return nil;
    NSUInteger bodyOffset = NSMaxRange(range);
    return [response subdataWithRange:NSMakeRange(bodyOffset, response.length - bodyOffset)];
}

static BOOL VCamWriteAllToFD(int fd, const uint8_t *bytes, size_t length) {
    size_t offset = 0;
    while (offset < length) {
        ssize_t amount = write(fd, bytes + offset, length - offset);
        if (amount < 0) {
            if (errno == EINTR) continue;
            return NO;
        }
        if (amount == 0) return NO;
        offset += (size_t)amount;
    }
    return YES;
}

static BOOL VCamHTTPDownloadToFile(NSString *requestPath, NSString *destinationPath) {
    int socketFD = VCamConnectToServer();
    if (socketFD < 0) return NO;

    NSString *request = [NSString stringWithFormat:@"GET %@ HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n", requestPath];
    if (!VCamSocketSendAll(socketFD, request.UTF8String, request.length)) {
        close(socketFD);
        return NO;
    }

    NSMutableData *headerBuffer = [NSMutableData data];
    NSData *separator = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t buffer[64 * 1024];
    BOOL headerParsed = NO;
    int outputFD = -1;
    unsigned long long expectedLength = ULLONG_MAX;
    unsigned long long written = 0;
    BOOL success = YES;
    const unsigned long long maximumFileSize = 1024ULL * 1024ULL * 1024ULL;

    while (YES) {
        ssize_t amount = recv(socketFD, buffer, sizeof(buffer), 0);
        if (amount < 0) {
            if (errno == EINTR) continue;
            success = NO;
            break;
        }
        if (amount == 0) break;

        const uint8_t *bodyBytes = buffer;
        size_t bodyLength = (size_t)amount;

        if (!headerParsed) {
            [headerBuffer appendBytes:buffer length:(NSUInteger)amount];
            NSRange range = [headerBuffer rangeOfData:separator options:0 range:NSMakeRange(0, headerBuffer.length)];
            if (range.location == NSNotFound) {
                if (headerBuffer.length > 16 * 1024) success = NO;
                if (!success) break;
                continue;
            }
            if (range.location > 16 * 1024) {
                success = NO;
                break;
            }

            NSData *headerData = [headerBuffer subdataWithRange:NSMakeRange(0, range.location)];
            NSString *headers = [[NSString alloc] initWithData:headerData encoding:NSUTF8StringEncoding];
            if (![headers hasPrefix:@"HTTP/1.1 200"] && ![headers hasPrefix:@"HTTP/1.0 200"]) {
                success = NO;
                break;
            }

            for (NSString *line in [headers componentsSeparatedByString:@"\r\n"]) {
                if ([line.lowercaseString hasPrefix:@"content-length:"]) {
                    NSString *value = [[line componentsSeparatedByString:@":"] lastObject];
                    expectedLength = (unsigned long long)value.longLongValue;
                    break;
                }
            }
            if (expectedLength == ULLONG_MAX || expectedLength == 0 || expectedLength > maximumFileSize) {
                success = NO;
                break;
            }

            outputFD = open(destinationPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0600);
            if (outputFD < 0) {
                success = NO;
                break;
            }

            NSUInteger bodyOffset = NSMaxRange(range);
            NSUInteger available = headerBuffer.length - bodyOffset;
            bodyBytes = (const uint8_t *)headerBuffer.bytes + bodyOffset;
            bodyLength = available;
            headerParsed = YES;
        }

        if (headerParsed && bodyLength > 0) {
            if (written + bodyLength > expectedLength || written + bodyLength > maximumFileSize ||
                !VCamWriteAllToFD(outputFD, bodyBytes, bodyLength)) {
                success = NO;
                break;
            }
            written += bodyLength;
        }
    }

    if (outputFD >= 0) close(outputFD);
    close(socketFD);
    if (!headerParsed || expectedLength == ULLONG_MAX || written != expectedLength) success = NO;
    if (!success) unlink(destinationPath.fileSystemRepresentation);
    return success;
}

static NSDictionary *VCamFetchRemoteState(void) {
    NSData *data = VCamHTTPGet(@"/state");
    if (!data) {
        NSLog(@"[VCam Pro] No se pudo consultar el IPC de SpringBoard en 127.0.0.1:47831.");
        return nil;
    }

    NSError *jsonError = nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (![object isKindOfClass:[NSDictionary class]]) {
        NSLog(@"[VCam Pro] Respuesta IPC inválida: %@", jsonError);
        return nil;
    }
    return object;
}

static NSString *VCamDownloadCurrentMedia(NSString *extension, NSInteger revision) {
    NSString *safeExtension = extension.lowercaseString;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789"];
    safeExtension = [[safeExtension componentsSeparatedByCharactersInSet:allowed.invertedSet] componentsJoinedByString:@""];
    if (safeExtension.length == 0 || safeExtension.length > 8) safeExtension = @"mp4";

    NSString *filename = [NSString stringWithFormat:@"vcam_shared_%ld.%@", (long)revision, safeExtension];
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:filename];
    if (!VCamHTTPDownloadToFile([NSString stringWithFormat:@"/media?revision=%ld", (long)revision], path)) {
        NSLog(@"[VCam Pro] No se pudo descargar el medio compartido desde SpringBoard.");
        return nil;
    }
    return path;
}

static void VCamRefreshFromServer(void) {
    if (!g_syncQueue) return;

    dispatch_async(g_syncQueue, ^{
        NSDictionary *state = VCamFetchRemoteState();
        if (!state) return;

        BOOL enabled = [state[@"enabled"] boolValue];
        NSInteger mediaRevision = [state[@"mediaRevision"] integerValue];
        NSInteger stateRevision = [state[@"stateRevision"] integerValue];
        CGFloat zoom = [state[@"zoom"] doubleValue];
        CGFloat offsetX = [state[@"offsetX"] doubleValue];
        CGFloat offsetY = [state[@"offsetY"] doubleValue];
        NSInteger rotationDegrees = [state[@"rotationDegrees"] integerValue];
        BOOL mirrorEnabled = [state[@"mirrorEnabled"] boolValue];
        BOOL motionEnabled = [state[@"motionEnabled"] boolValue];
        CGFloat buttonX = [state[@"buttonX"] doubleValue];
        CGFloat buttonY = [state[@"buttonY"] doubleValue];

        VCamSetLocalEnabled(enabled);
        VCamSetPreviewOverlaysVisible(enabled);
        g_vcamZoom = MAX(0.5, MIN(4.0, zoom));
        g_vcamOffsetX = MAX(-1.0, MIN(1.0, offsetX));
        g_vcamOffsetY = MAX(-1.0, MIN(1.0, offsetY));
        g_vcamRotationDegrees = ((rotationDegrees % 360) + 360) % 360;
        g_vcamMirrorEnabled = mirrorEnabled;
        g_vcamMotionEnabled = motionEnabled;
        g_vcamButtonX = MAX(0.04, MIN(0.96, buttonX));
        g_vcamButtonY = MAX(0.04, MIN(0.96, buttonY));

        dispatch_async(dispatch_get_main_queue(), ^{
            VCamUpdateButton();
            VCamClampButton();
            if (g_isSpringBoardProcess && g_adjustmentPanel) {
                if (g_adjustmentPreviewRevision != mediaRevision) {
                    g_adjustmentPreviewRevision = mediaRevision;
                    [(id)g_adjustmentPanel performSelector:@selector(reloadPreview)];
                }
                [(id)g_adjustmentPanel performSelector:@selector(refreshFraming)];
            }
        });

        if (g_isSpringBoardProcess) return;

        UIApplication *application = [UIApplication sharedApplication];
        MediaManager *manager = [MediaManager sharedManager];
        [manager setZoom:g_vcamZoom offsetX:g_vcamOffsetX offsetY:g_vcamOffsetY];
        [manager setRotationDegrees:g_vcamRotationDegrees];
        [manager setMirrorEnabled:g_vcamMirrorEnabled];
        [manager setMotionEnabled:g_vcamMotionEnabled];

        if (enabled &&
            application.applicationState == UIApplicationStateActive &&
            manager.isReady &&
            manager.mode == VCamMediaModePhoto) {
            NSData *updatedStillJPEG = [manager nextPhotoData];
            if (updatedStillJPEG) VCamUpdatePreviewOverlaysWithJPEG(updatedStillJPEG);
        }

        if (!enabled) {
            [manager stop];
            NSLog(@"[VCam Pro] Estado remoto desactivado (rev %ld).", (long)stateRevision);
        } else if (mediaRevision > 0 && mediaRevision != g_lastMediaRevision &&
                   mediaRevision != g_failedMediaRevision && g_loadingMediaRevision == -1) {
            if (g_mediaLoadAttemptRevision != mediaRevision) {
                g_mediaLoadAttemptRevision = mediaRevision;
                g_mediaLoadAttemptCount = 0;
            }
            g_mediaLoadAttemptCount += 1;
            NSUInteger mediaLoadAttempt = g_mediaLoadAttemptCount;
            g_loadingMediaRevision = mediaRevision;
            NSString *extension = [state[@"mediaExtension"] isKindOfClass:[NSString class]] ? state[@"mediaExtension"] : @"mp4";
            NSString *mediaType = [state[@"mediaType"] isKindOfClass:[NSString class]] ? state[@"mediaType"] : @"video";
            NSString *localPath = VCamDownloadCurrentMedia(extension, mediaRevision);
            if (!localPath) {
                g_loadingMediaRevision = -1;
                if (mediaLoadAttempt >= 5) {
                    g_failedMediaRevision = mediaRevision;
                    NSLog(@"[VCam Pro] No se pudo descargar la revisión %ld tras %lu intentos.",
                          (long)mediaRevision, (unsigned long)mediaLoadAttempt);
                } else {
                    NSTimeInterval retryDelay = MIN(2.0, 0.35 * mediaLoadAttempt);
                    NSLog(@"[VCam Pro] Descarga de revisión %ld fallida; reintento %lu/5 en %.2fs.",
                          (long)mediaRevision, (unsigned long)(mediaLoadAttempt + 1), retryDelay);
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                 (int64_t)(retryDelay * NSEC_PER_SEC)),
                                   g_syncQueue, ^{
                        VCamRefreshFromServer();
                    });
                }
                return;
            }

            NSURL *localURL = [NSURL fileURLWithPath:localPath];
            [manager stop];
            [manager loadMediaFromURL:localURL mediaType:mediaType completion:^(BOOL success, NSError *error) {
                g_loadingMediaRevision = -1;
                if (success && VCamIsEnabled()) {
                    g_lastMediaRevision = mediaRevision;
                    g_failedMediaRevision = -1;
                    g_mediaLoadAttemptRevision = -1;
                    g_mediaLoadAttemptCount = 0;
                    [manager setZoom:g_vcamZoom offsetX:g_vcamOffsetX offsetY:g_vcamOffsetY];
                    [manager setRotationDegrees:g_vcamRotationDegrees];
                    if ([mediaType isEqualToString:@"image"]) {
                        NSData *stillJPEG = [manager nextPhotoData];
                        if (stillJPEG) VCamUpdatePreviewOverlaysWithJPEG(stillJPEG);
                    }
                    if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
                        [manager start];
                    } else {
                        [manager stop];
                    }
                    NSLog(@"[VCam Pro] Medio remoto listo (rev %ld).", (long)mediaRevision);
                } else {
                    if (!success) {
                        if (mediaLoadAttempt >= 5) {
                            g_failedMediaRevision = mediaRevision;
                            NSLog(@"[VCam Pro] Falló la carga local de la revisión %ld tras %lu intentos.",
                                  (long)mediaRevision, (unsigned long)mediaLoadAttempt);
                        } else {
                            NSTimeInterval retryDelay = MIN(2.0, 0.35 * mediaLoadAttempt);
                            NSLog(@"[VCam Pro] Carga de revisión %ld fallida; reintento %lu/5 en %.2fs: %@",
                                  (long)mediaRevision, (unsigned long)(mediaLoadAttempt + 1),
                                  retryDelay, error);
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                         (int64_t)(retryDelay * NSEC_PER_SEC)),
                                           g_syncQueue, ^{
                                VCamRefreshFromServer();
                            });
                        }
                    }
                }
                // On success, immediately check whether a newer choice arrived during the load.
                if (success) VCamRefreshFromServer();
            }];
        } else if (enabled) {
            if (application.applicationState == UIApplicationStateActive && manager.isReady) {
                [manager start];
            } else if (application.applicationState != UIApplicationStateActive) {
                [manager stop];
            } else {
                NSLog(@"[VCam Pro] VCam está activado pero este proceso aún no tiene medio cargado.");
            }
        }
    });
}

static void VCamDarwinNotificationCallback(CFNotificationCenterRef center,
                                          void *observer,
                                          CFStringRef name,
                                          const void *object,
                                          CFDictionaryRef userInfo) {
    VCamRefreshFromServer();
}

static void VCamRegisterIPCObserver(void) {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    &g_darwinObserverToken,
                                    VCamDarwinNotificationCallback,
                                    CFSTR("com.vcam.pro.state.changed"),
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}

#pragma mark - Preview Layer Bridge

static void VCamSetPreviewOverlayContents(CGImageRef image) {
    if (!image) return;
    CGImageRef retainedImage = CGImageRetain(image);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray<CALayer *> *layers = g_previewOverlayLayers.allObjects ?: @[];
        for (CALayer *layer in layers) {
            layer.contents = (__bridge id)retainedImage;
            layer.hidden = NO;
        }
        CGImageRelease(retainedImage);
    });
}

static void VCamSetPreviewOverlaysVisible(BOOL visible) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray<CALayer *> *layers = g_previewOverlayLayers.allObjects ?: @[];
        for (CALayer *layer in layers) {
            layer.hidden = !visible;
        }
    });
}

static void VCamUpdatePreviewOverlaysWithSampleBuffer(CMSampleBufferRef sampleBuffer) {
    if (!sampleBuffer || !VCamIsEnabled()) return;
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!imageBuffer) return;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_previewCIContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
    });

    CIImage *image = [CIImage imageWithCVPixelBuffer:imageBuffer];
    CGRect extent = image.extent;
    if (CGRectIsEmpty(extent) || extent.size.width < 2.0 || extent.size.height < 2.0) return;

    CGImageRef cgImage = [g_previewCIContext createCGImage:image fromRect:extent];
    if (!cgImage) return;
    VCamSetPreviewOverlayContents(cgImage);
    CGImageRelease(cgImage);
}

static void VCamUpdatePreviewOverlaysWithJPEG(NSData *jpegData) {
    if (!jpegData.length || !VCamIsEnabled()) return;
    UIImage *image = [UIImage imageWithData:jpegData];
    if (image.CGImage) VCamSetPreviewOverlayContents(image.CGImage);
}

static void VCamStartPreviewPump(void);

static void VCamRenderPixelBufferToPreview(CVPixelBufferRef pixelBuffer) {
    if (!pixelBuffer) return;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_previewCIContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
    });

    CIImage *image = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    CGRect extent = image.extent;
    if (CGRectIsEmpty(extent) || extent.size.width < 2.0 || extent.size.height < 2.0) return;

    CGImageRef cgImage = [g_previewCIContext createCGImage:image fromRect:extent];
    if (!cgImage) return;
    VCamSetPreviewOverlayContents(cgImage);
    CGImageRelease(cgImage);
}

static void VCamPreviewPumpTick(void) {
    if (!VCamIsEnabled() || ![MediaManager sharedManager].isReady) return;
    if (g_previewOverlayLayers.allObjects.count == 0) return;

    MediaManager *manager = [MediaManager sharedManager];

    // Still images are pushed once when the media revision is loaded or the
    // preview layer is attached. Re-encoding JPEG at 30 Hz would waste CPU.
    if (manager.mode != VCamMediaModeVideo) return;

    CFTimeInterval now = CACurrentMediaTime();
    BOOL dataOutputIsFeedingPreview = NO;
    @synchronized ([AVCaptureVideoDataOutput class]) {
        dataOutputIsFeedingPreview =
            (g_lastVideoOutputCallbackTime > 0.0 &&
             (now - g_lastVideoOutputCallbackTime) < 0.5);
    }

    // If AVFoundation is already delivering virtual frames through the
    // video-data delegate, let that callback drive the preview. Only pump
    // the media reader when the app uses a preview layer without a data output.
    if (dataOutputIsFeedingPreview) return;

    CMSampleBufferRef frame =
        [manager nextVideoFrameForSize:CGSizeMake(640, 480)
                           pixelFormat:kCVPixelFormatType_32BGRA];
    if (!frame) return;

    VCamRenderPixelBufferToPreview(CMSampleBufferGetImageBuffer(frame));
    CFRelease(frame);
}

static void VCamStartPreviewPump(void) {
    if (g_previewPumpTimer) return;

    dispatch_queue_t queue = dispatch_get_main_queue();
    g_previewPumpTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    if (!g_previewPumpTimer) return;

    dispatch_source_set_timer(g_previewPumpTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(NSEC_PER_SEC / 30),
                              (uint64_t)(NSEC_PER_MSEC * 3));
    dispatch_source_set_event_handler(g_previewPumpTimer, ^{
        VCamPreviewPumpTick();
    });
    dispatch_resume(g_previewPumpTimer);
}

static void VCamAttachPreviewOverlay(AVCaptureVideoPreviewLayer *previewLayer) {
    if (!previewLayer) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        CALayer *existing = objc_getAssociatedObject(previewLayer, kVCamPreviewOverlayKey);
        if (existing) return;

        CALayer *overlay = [CALayer layer];
        overlay.name = @"VCamPro.VirtualPreview";
        overlay.frame = previewLayer.bounds;
        overlay.contentsGravity = kCAGravityResizeAspectFill;
        overlay.contentsScale = [UIScreen mainScreen].scale;
        overlay.masksToBounds = YES;
        overlay.zPosition = CGFLOAT_MAX;
        overlay.hidden = !VCamIsEnabled();

        [previewLayer addSublayer:overlay];
        objc_setAssociatedObject(previewLayer,
                                 kVCamPreviewOverlayKey,
                                 overlay,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        if (!g_previewOverlayLayers) {
            g_previewOverlayLayers = [NSHashTable weakObjectsHashTable];
        }
        [g_previewOverlayLayers addObject:overlay];

        if (VCamIsEnabled() && [MediaManager sharedManager].mode == VCamMediaModePhoto) {
            NSData *stillJPEG = [[MediaManager sharedManager] nextPhotoData];
            if (stillJPEG) VCamUpdatePreviewOverlaysWithJPEG(stillJPEG);
        }
        VCamStartPreviewPump();
    });
}

#pragma mark - Client Camera Orientation Diagnostics

static void VCamLogClientConnectionOrientation(AVCaptureOutput *output,
                                                CMSampleBufferRef sampleBuffer,
                                                CVImageBufferRef pixelBuffer,
                                                AVCaptureConnection *connection,
                                                BOOL sampleMarker,
                                                BOOL pixelMarker) {
    NSInteger connectionOrientation = NSIntegerMin;
    BOOL orientationSupported = NO;
    BOOL orientationSupportAvailable = NO;
    BOOL isMirrored = NO;
    BOOL mirroringSupported = NO;
    BOOL mirroringSupportAvailable = NO;
    CGFloat rotationAngle = 0.0;
    BOOL rotationAngleAvailable = NO;

    if (connection) {
        SEL orientationSelector = sel_registerName("videoOrientation");
        if ([connection respondsToSelector:orientationSelector]) {
            connectionOrientation = ((NSInteger (*)(id, SEL))objc_msgSend)(
                connection, orientationSelector);
        }

        SEL orientationSupportSelector = sel_registerName("isVideoOrientationSupported");
        if ([connection respondsToSelector:orientationSupportSelector]) {
            orientationSupported = ((BOOL (*)(id, SEL))objc_msgSend)(
                connection, orientationSupportSelector);
            orientationSupportAvailable = YES;
        }

        SEL mirroredSelector = sel_registerName("isVideoMirrored");
        if ([connection respondsToSelector:mirroredSelector]) {
            isMirrored = ((BOOL (*)(id, SEL))objc_msgSend)(connection, mirroredSelector);
        }

        SEL mirroringSupportSelector = sel_registerName("isVideoMirroringSupported");
        if ([connection respondsToSelector:mirroringSupportSelector]) {
            mirroringSupported = ((BOOL (*)(id, SEL))objc_msgSend)(
                connection, mirroringSupportSelector);
            mirroringSupportAvailable = YES;
        }

        SEL rotationSelector = sel_registerName("videoRotationAngle");
        if ([connection respondsToSelector:rotationSelector]) {
            rotationAngle = ((CGFloat (*)(id, SEL))objc_msgSend)(connection, rotationSelector);
            rotationAngleAvailable = YES;
        }
    }

    NSInteger interfaceOrientation = 0;
    UIApplication *application = [UIApplication sharedApplication];
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]] ||
            scene.activationState != UISceneActivationStateForegroundActive) continue;
        interfaceOrientation = (NSInteger)((UIWindowScene *)scene).interfaceOrientation;
        break;
    }

    size_t width = pixelBuffer ? CVPixelBufferGetWidth(pixelBuffer) : 0;
    size_t height = pixelBuffer ? CVPixelBufferGetHeight(pixelBuffer) : 0;
    OSType pixelFormat = pixelBuffer ? CVPixelBufferGetPixelFormatType(pixelBuffer) : 0;
    double presentationTime = sampleBuffer
        ? CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) : 0.0;
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"unknown.bundle";
    NSString *processName = NSProcessInfo.processInfo.processName ?: @"unknown-process";
    NSString *connectionKey = [NSString stringWithFormat:@"%p/%p", output, connection];
    NSString *signature = [NSString stringWithFormat:
        @"ui=%ld;vo=%ld;vos=%d;voa=%d;angle=%.1f;angleAvailable=%d;mirror=%d;mirrorSupported=%d;frame=%zux%zu;format=%u;sample=%d;pixel=%d",
        (long)interfaceOrientation, (long)connectionOrientation,
        orientationSupported, orientationSupportAvailable,
        rotationAngle, rotationAngleAvailable, isMirrored,
        mirroringSupported, width, height, (unsigned int)pixelFormat,
        sampleMarker, pixelMarker];

    NSUInteger index = 0;
    BOOL shouldEmit = NO;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    @synchronized ([AVCaptureVideoDataOutput class]) {
        if (!g_vcamClientConnectionDiagnostics) {
            g_vcamClientConnectionDiagnostics = [NSMutableDictionary dictionary];
        }
        NSDictionary *previous = g_vcamClientConnectionDiagnostics[connectionKey];
        NSString *previousSignature = [previous[@"signature"] isKindOfClass:[NSString class]]
            ? previous[@"signature"] : nil;
        NSTimeInterval previousTime = [previous[@"time"] doubleValue];
        BOOL changed = ![previousSignature isEqualToString:signature];
        BOOL heartbeat = (now - previousTime) >= 0.75;
        shouldEmit = !previous || changed || heartbeat;
        if (shouldEmit) {
            index = ++g_vcamClientConnectionDiagnosticCount;
            g_vcamClientConnectionDiagnostics[connectionKey] = @{
                @"signature": signature,
                @"time": @(now)
            };
        }
    }
    if (!shouldEmit) return;

    NSString *event = [NSString stringWithFormat:
        @"[VCam Pro/LiveDiag] CLIENT_CONNECTION #%lu timestamp=%.3f uptime=%.3f app=%@ process=%@ output=%s connection=%s interfaceOrientation=%ld videoOrientation=%ld orientationSupported=%d orientationSupportAvailable=%d videoRotationAngle=%.1f rotationAngleAvailable=%d mirrored=%d mirroringSupported=%d mirroringSupportAvailable=%d frame=%zux%zu pixelFormat=%u pts=%.6f sampleMarker=%d pixelMarker=%d",
        (unsigned long)index,
        [NSDate date].timeIntervalSince1970,
        now,
        bundleID,
        processName,
        output ? object_getClassName(output) : "(null)",
        connection ? object_getClassName(connection) : "(null)",
        (long)interfaceOrientation,
        (long)connectionOrientation,
        orientationSupported,
        orientationSupportAvailable,
        rotationAngle,
        rotationAngleAvailable,
        isMirrored,
        mirroringSupported,
        mirroringSupportAvailable,
        width,
        height,
        (unsigned int)pixelFormat,
        presentationTime,
        sampleMarker,
        pixelMarker];

    VCamSendOrientationDiagnosticEvent(event);
}

#pragma mark - Video Delegate Proxy

@interface VCamSampleBufferDelegateProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, weak) id<AVCaptureVideoDataOutputSampleBufferDelegate> originalDelegate;
- (instancetype)initWithDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate;
@end

@implementation VCamSampleBufferDelegateProxy

- (instancetype)initWithDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate {
    self = [super init];
    if (self) _originalDelegate = delegate;
    return self;
}

- (BOOL)respondsToSelector:(SEL)selector {
    return [super respondsToSelector:selector] || [self.originalDelegate respondsToSelector:selector];
}

- (id)forwardingTargetForSelector:(SEL)selector {
    if ([self.originalDelegate respondsToSelector:selector]) return self.originalDelegate;
    return [super forwardingTargetForSelector:selector];
}

- (void)captureOutput:(AVCaptureOutput *)output
 didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {

    @synchronized ([AVCaptureVideoDataOutput class]) {
        g_lastVideoOutputCallbackTime = CACurrentMediaTime();
    }

    id<AVCaptureVideoDataOutputSampleBufferDelegate> delegate = self.originalDelegate;
    if (!delegate) {
        NSLog(@"[VCam Pro] El delegado original de AVCaptureVideoDataOutput ya no existe.");
        return;
    }

    // The mediaserverd engine marks frames it has already replaced. Bypass
    // app-local decoding for that exact sample to avoid double advancement.
    CFTypeRef systemMarker = CMGetAttachment(sampleBuffer,
                                              CFSTR("com.vcam.pro.systemreplacement.v1"),
                                              NULL);
    CVImageBufferRef sampleImage = CMSampleBufferGetImageBuffer(sampleBuffer);
    CFTypeRef pixelMarker = sampleImage
        ? CVBufferGetAttachment(sampleImage,
                                CFSTR("com.vcam.pro.systemreplacement.v1"),
                                NULL)
        : NULL;
    // Log the app-side connection for both marked and unmarked callbacks.
    // A missing marker is itself useful evidence about the handoff path.
    VCamLogClientConnectionOrientation(output,
                                       sampleBuffer,
                                       sampleImage,
                                       connection,
                                       systemMarker == kCFBooleanTrue,
                                       pixelMarker == kCFBooleanTrue);

    if (systemMarker == kCFBooleanTrue || pixelMarker == kCFBooleanTrue) {
        [delegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
        return;
    }

    NSUInteger callbackNumber = 0;
    @synchronized ([AVCaptureVideoDataOutput class]) {
        g_vcamVideoCallbackCount += 1;
        callbackNumber = g_vcamVideoCallbackCount;
    }
    if (callbackNumber == 1 || callbackNumber % 180 == 0) {
        NSUInteger replacementCount = 0;
        @synchronized ([AVCaptureVideoDataOutput class]) {
            replacementCount = g_vcamVideoReplacementCount;
        }
        NSLog(@"[VCam Pro] AVCaptureVideoDataOutput callback #%lu; replacements=%lu; enabled=%d; ready=%d",
              (unsigned long)callbackNumber,
              (unsigned long)replacementCount,
              VCamIsEnabled(),
              [MediaManager sharedManager].isReady);
    }

    if (!VCamIsEnabled() || ![MediaManager sharedManager].isReady) {
        [delegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
        return;
    }

    CVImageBufferRef originalImage = CMSampleBufferGetImageBuffer(sampleBuffer);
    CGSize frameSize = CGSizeMake(1280, 720);
    OSType pixelFormat = kCVPixelFormatType_32BGRA;

    if (originalImage) {
        frameSize = CGSizeMake(CVPixelBufferGetWidth(originalImage), CVPixelBufferGetHeight(originalImage));
        pixelFormat = CVPixelBufferGetPixelFormatType(originalImage);
    }

    if ([output isKindOfClass:[AVCaptureVideoDataOutput class]]) {
        NSDictionary *settings = ((AVCaptureVideoDataOutput *)output).videoSettings;
        NSNumber *requestedFormat = settings[(id)kCVPixelBufferPixelFormatTypeKey];
        if (requestedFormat) pixelFormat = (OSType)requestedFormat.unsignedIntValue;
    }

    CMSampleBufferRef virtualFrame = [[MediaManager sharedManager] nextVideoFrameForSize:frameSize pixelFormat:pixelFormat];
    if (!virtualFrame) {
        if (callbackNumber == 1 || callbackNumber % 180 == 0) {
            NSLog(@"[VCam Pro] No se pudo generar el fotograma virtual; se entrega el fotograma real.");
        }
        [delegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
        return;
    }

    VCamUpdatePreviewOverlaysWithSampleBuffer(virtualFrame);
    @synchronized ([AVCaptureVideoDataOutput class]) {
        g_vcamVideoReplacementCount += 1;
    }
    [delegate captureOutput:output didOutputSampleBuffer:virtualFrame fromConnection:connection];
    CFRelease(virtualFrame);
}

- (void)captureOutput:(AVCaptureOutput *)output
 didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    id<AVCaptureVideoDataOutputSampleBufferDelegate> delegate = self.originalDelegate;
    if ([delegate respondsToSelector:@selector(captureOutput:didDropSampleBuffer:fromConnection:)]) {
        [delegate captureOutput:output didDropSampleBuffer:sampleBuffer fromConnection:connection];
    }
}

@end

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue {
    if (!delegate) {
        objc_setAssociatedObject(self, kVCamDelegateProxyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(nil, queue);
        return;
    }

    if ([delegate isKindOfClass:[VCamSampleBufferDelegateProxy class]]) {
        %orig(delegate, queue);
        return;
    }

    VCamSampleBufferDelegateProxy *proxy = [[VCamSampleBufferDelegateProxy alloc] initWithDelegate:delegate];
    objc_setAssociatedObject(self, kVCamDelegateProxyKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSDictionary *settings = self.videoSettings;
    NSNumber *format = settings[(id)kCVPixelBufferPixelFormatTypeKey];
    NSLog(@"[VCam Pro] Delegate de vídeo interceptado; formato solicitado=%@",
          format ?: @"default");
    %orig(proxy, queue);

    NSUInteger attachIndex = 0;
    @synchronized ([AVCaptureVideoDataOutput class]) {
        if (g_vcamClientOutputAttachDiagnosticCount < 4) {
            attachIndex = ++g_vcamClientOutputAttachDiagnosticCount;
        }
    }
    if (attachIndex > 0) {
        NSString *event = [NSString stringWithFormat:
            @"[VCam Pro/OrientationDiag] CLIENT_VIDEO_OUTPUT_ATTACHED #%lu timestamp=%.3f output=%s pixelFormat=%@",
            (unsigned long)attachIndex,
            [NSDate date].timeIntervalSince1970,
            object_getClassName(self),
            format ?: @"default"];
        VCamSendOrientationDiagnosticEvent(event);
    }
}

%end

// Observe the orientation contract requested by each app without changing it.
%hook AVCaptureConnection

- (void)setVideoOrientation:(AVCaptureVideoOrientation)orientation {
    %orig(orientation);

    NSInteger actual = NSIntegerMin;
    SEL getter = sel_registerName("videoOrientation");
    if ([self respondsToSelector:getter]) {
        actual = ((NSInteger (*)(id, SEL))objc_msgSend)(self, getter);
    }
    NSString *event = [NSString stringWithFormat:
        @"[VCam Pro/LiveDiag] CONNECTION_SET_VIDEO_ORIENTATION timestamp=%.3f app=%@ process=%@ connection=%s requested=%ld actual=%ld",
        [NSDate date].timeIntervalSince1970,
        NSBundle.mainBundle.bundleIdentifier ?: @"unknown.bundle",
        NSProcessInfo.processInfo.processName ?: @"unknown-process",
        object_getClassName(self),
        (long)orientation,
        (long)actual];
    VCamSendOrientationDiagnosticEvent(event);
}

%end

// Let each AVFoundation client retain its own requested video orientation.
// The replacement frames are already rendered into the source buffer dimensions;
// overriding this contract globally makes some clients rotate them a second time.
%hook AVCaptureVideoPreviewLayer

- (instancetype)initWithSession:(AVCaptureSession *)session {
    id result = %orig(session);
    if (result) VCamAttachPreviewOverlay((AVCaptureVideoPreviewLayer *)result);
    return result;
}

+ (instancetype)layerWithSession:(AVCaptureSession *)session {
    id result = %orig(session);
    if (result) VCamAttachPreviewOverlay((AVCaptureVideoPreviewLayer *)result);
    return result;
}

- (void)setSession:(AVCaptureSession *)session {
    %orig(session);
    VCamAttachPreviewOverlay(self);
}

- (void)setBounds:(CGRect)bounds {
    %orig(bounds);
    CALayer *overlay = objc_getAssociatedObject(self, kVCamPreviewOverlayKey);
    if (overlay) overlay.frame = self.bounds;
}

- (void)setFrame:(CGRect)frame {
    %orig(frame);
    CALayer *overlay = objc_getAssociatedObject(self, kVCamPreviewOverlayKey);
    if (overlay) overlay.frame = self.bounds;
}

%end

#pragma mark - Still Photo Result Hook

static BOOL VCamIsJPEGData(NSData *data) {
    if (data.length < 3) return NO;
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    return bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF;
}

static NSString *VCamDetectedImageUTI(NSData *data) {
    if (!data.length) return nil;
    const uint8_t *bytes = (const uint8_t *)data.bytes;

    if (VCamIsJPEGData(data)) return @"public.jpeg";

    static const uint8_t pngSignature[8] = {0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A};
    if (data.length >= sizeof(pngSignature) &&
        memcmp(bytes, pngSignature, sizeof(pngSignature)) == 0) {
        return @"public.png";
    }

    if (data.length >= 12 && memcmp(bytes + 4, "ftyp", 4) == 0) {
        NSString *brand = [[NSString alloc] initWithBytes:bytes + 8
                                                   length:4
                                                 encoding:NSASCIIStringEncoding];
        NSSet *heifBrands = [NSSet setWithArray:@[@"heic", @"heix", @"hevc", @"hevx", @"mif1", @"msf1"]];
        if ([heifBrands containsObject:brand.lowercaseString]) return @"public.heic";
    }

    return nil;
}

static NSData *VCamEncodeJPEGAsUTI(NSData *jpegData, NSString *uti) {
    if (!jpegData.length || !uti.length) return nil;
    if ([uti isEqualToString:@"public.jpeg"] && VCamIsJPEGData(jpegData)) return jpegData;

    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)jpegData, NULL);
    if (!source) return nil;

    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    if (!image) return nil;

    NSMutableData *encoded = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)encoded,
                                                                          (__bridge CFStringRef)uti,
                                                                          1,
                                                                          NULL);
    if (!destination) {
        CGImageRelease(image);
        return nil;
    }

    CGImageDestinationAddImage(destination, image, NULL);
    BOOL finished = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    CGImageRelease(image);

    return finished ? encoded : nil;
}

static char kVCamPhotoReplacementDataKey;

static NSData *VCamReplacementDataForPhoto(AVCapturePhoto *photo) {
    if (!photo) return nil;
    NSData *cached = objc_getAssociatedObject(photo, &kVCamPhotoReplacementDataKey);
    if (cached.length > 0) return cached;

    NSData *generated = [[MediaManager sharedManager] nextPhotoData];
    if (!generated.length || !VCamIsJPEGData(generated)) return nil;

    // Both the embedded preview and the saved file must represent the same
    // virtual frame, even when AVFoundation asks for them in separate calls.
    objc_setAssociatedObject(photo,
                             &kVCamPhotoReplacementDataKey,
                             generated,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return generated;
}

%hook AVCapturePhoto

- (CGImageRef)previewCGImageRepresentation {
    CGImageRef original = %orig;
    if (!original || !VCamIsEnabled() || ![MediaManager sharedManager].isReady) return original;

    NSData *virtualJPEG = VCamReplacementDataForPhoto(self);
    if (!virtualJPEG.length) return original;

    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)virtualJPEG, NULL);
    if (!source) return original;

    CGImageRef replacement = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    if (!replacement) return original;

    NSLog(@"[VCam Pro] Miniatura de AVCapturePhoto sustituida por el fotograma virtual.");
    // The AVFoundation method returns a non-owned CGImageRef. Autorelease the
    // Create-rule result so ARC keeps it alive for the caller's autorelease pool.
    return (CGImageRef)CFAutorelease(replacement);
}

- (NSData *)fileDataRepresentation {
    NSData *original = %orig;
    if (!VCamIsEnabled() || ![MediaManager sharedManager].isReady) return original;

    // JPEG, PNG y HEIC pueden regenerarse desde la imagen virtual. RAW y
    // contenedores desconocidos se conservan para no devolver datos corruptos.
    NSString *uti = VCamDetectedImageUTI(original);
    if (!uti) return original;

    NSData *virtualJPEG = VCamReplacementDataForPhoto(self);
    NSData *replacement = VCamEncodeJPEGAsUTI(virtualJPEG, uti);
    if (replacement.length > 0) {
        NSLog(@"[VCam Pro] AVCapturePhoto sustituida en formato %@.", uti);
        return replacement;
    }

    NSLog(@"[VCam Pro] No se pudo codificar la captura virtual como %@; se conserva la original.", uti);
    return original;
}

%end

// Compatibilidad con aplicaciones antiguas que solicitan una representación JPEG.
%hook AVCaptureStillImageOutput

+ (NSData *)jpegStillImageNSDataRepresentation:(CMSampleBufferRef)jpegSampleBuffer {
    if (VCamIsEnabled() && [MediaManager sharedManager].isReady) {
        NSData *replacement = [[MediaManager sharedManager] nextPhotoData];
        if (replacement.length > 0 && VCamIsJPEGData(replacement)) {
            NSLog(@"[VCam Pro] Conversión JPEG de AVCaptureStillImageOutput sustituida.");
            return replacement;
        }
    }
    return %orig(jpegSampleBuffer);
}

%end


// AVCaptureMovieFileOutput is intentionally left untouched in this release.
// Replacing a completed movie requires an AVAssetExportSession transcode that
// matches the destination container; copying bytes under a different extension
// could produce an unreadable recording.

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
    CGPoint center = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
    CGFloat halfWidth = CGRectGetWidth(self.bounds) * 0.5;
    CGFloat halfHeight = CGRectGetHeight(self.bounds) * 0.5;

    center.x = MAX(halfWidth + kVCamButtonMargin, MIN(CGRectGetWidth(container.bounds) - halfWidth - kVCamButtonMargin, center.x));
    center.y = MAX(halfHeight + kVCamButtonMargin, MIN(CGRectGetHeight(container.bounds) - halfHeight - kVCamButtonMargin, center.y));

    self.center = center;
    [gesture setTranslation:CGPointZero inView:container];

    if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled) {
        CGFloat targetX = center.x < CGRectGetMidX(container.bounds) ? halfWidth + kVCamButtonMargin : CGRectGetWidth(container.bounds) - halfWidth - kVCamButtonMargin;
        [UIView animateWithDuration:0.18 animations:^{
            self.center = CGPointMake(targetX, center.y);
        } completion:^(BOOL finished) {
            CGFloat normalizedX = self.center.x / MAX(1.0, CGRectGetWidth(container.bounds));
            CGFloat normalizedY = self.center.y / MAX(1.0, CGRectGetHeight(container.bounds));
            g_vcamButtonX = MAX(0.04, MIN(0.96, normalizedX));
            g_vcamButtonY = MAX(0.04, MIN(0.96, normalizedY));
            [[VCamSharedState sharedState] setButtonNormalizedX:g_vcamButtonX y:g_vcamButtonY];
        }];
    }
}

- (void)handleTap:(UITapGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateEnded) VCamShowMenu();
}

@end

#pragma mark - Passthrough Window

@interface VCamPassthroughWindow : UIWindow
@property (nonatomic, weak) UIButton *vcamButton;
@property (nonatomic, weak) UIView *interactivePanel;
@end

@implementation VCamPassthroughWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || self.alpha < 0.01 || !self.userInteractionEnabled) return nil;

    UIView *hit = [super hitTest:point withEvent:event];
    if (!hit) return nil;

    if (self.rootViewController.presentedViewController) return hit;

    UIButton *button = self.vcamButton;
    if (button && (hit == button || [hit isDescendantOfView:button])) return hit;

    UIView *panel = self.interactivePanel;
    if (panel && (hit == panel || [hit isDescendantOfView:panel])) return hit;
    return nil;
}

@end

#pragma mark - Compact Floating Adjustment Panel

@interface VCamAdjustmentPanel : UIView
@property (nonatomic, strong) UIView *headerView;
@property (nonatomic, strong) UIView *previewContainer;
@property (nonatomic, strong) UIImageView *previewImageView;
@property (nonatomic, strong) UIImage *sourcePreviewImage;
@property (nonatomic, strong) CIContext *previewCIContext;
@property (nonatomic, strong) UILabel *placeholderLabel;
@property (nonatomic, strong) UILabel *zoomLabel;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) UIPanGestureRecognizer *dragGesture;
- (void)reloadPreview;
- (void)refreshFraming;
@end

@implementation VCamAdjustmentPanel

- (UIButton *)controlButton:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:19 weight:UIFontWeightSemibold];
    button.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.13];
    button.layer.cornerRadius = 10.0;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.08].CGColor;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.backgroundColor = [UIColor colorWithWhite:0.055 alpha:0.96];
    self.layer.cornerRadius = 18.0;
    self.layer.borderWidth = 1.0;
    self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.16].CGColor;
    self.layer.shadowColor = UIColor.blackColor.CGColor;
    self.layer.shadowOpacity = 0.34;
    self.layer.shadowRadius = 18.0;
    self.layer.shadowOffset = CGSizeMake(0, 8);
    self.clipsToBounds = NO;

    _headerView = [[UIView alloc] init];
    _headerView.backgroundColor = UIColor.clearColor;
    [self addSubview:_headerView];

    UILabel *title = [[UILabel alloc] init];
    title.text = @"VCAM  ·  ENCUADRE";
    title.textColor = [UIColor colorWithWhite:1.0 alpha:0.94];
    title.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    title.textAlignment = NSTextAlignmentLeft;
    [_headerView addSubview:title];
    title.tag = 4802;

    _closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_closeButton setTitle:@"×" forState:UIControlStateNormal];
    [_closeButton setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.9] forState:UIControlStateNormal];
    _closeButton.titleLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightRegular];
    [_closeButton addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [_headerView addSubview:_closeButton];

    _dragGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePanelPan:)];
    _dragGesture.maximumNumberOfTouches = 1;
    _dragGesture.cancelsTouchesInView = NO;
    [_headerView addGestureRecognizer:_dragGesture];

    _previewContainer = [[UIView alloc] init];
    _previewContainer.backgroundColor = [UIColor colorWithWhite:0.0 alpha:1.0];
    _previewContainer.layer.cornerRadius = 11.0;
    _previewContainer.layer.borderWidth = 1.0;
    _previewContainer.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.12].CGColor;
    _previewContainer.clipsToBounds = YES;
    [self addSubview:_previewContainer];

    _previewImageView = [[UIImageView alloc] init];
    _previewImageView.contentMode = UIViewContentModeScaleToFill;
    _previewImageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _previewImageView.clipsToBounds = YES;
    _previewCIContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO,
                                                         kCIContextCacheIntermediates: @NO}];
    [_previewContainer addSubview:_previewImageView];

    _placeholderLabel = [[UILabel alloc] init];
    _placeholderLabel.text = @"Selecciona una foto o vídeo";
    _placeholderLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.58];
    _placeholderLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    _placeholderLabel.textAlignment = NSTextAlignmentCenter;
    _placeholderLabel.numberOfLines = 2;
    [_previewContainer addSubview:_placeholderLabel];

    UIButton *up = [self controlButton:@"↑" action:@selector(moveUp)];
    UIButton *left = [self controlButton:@"←" action:@selector(moveLeft)];
    UIButton *reset = [self controlButton:@"↺" action:@selector(resetTransform)];
    UIButton *right = [self controlButton:@"→" action:@selector(moveRight)];
    UIButton *down = [self controlButton:@"↓" action:@selector(moveDown)];
    UIButton *rotate = [self controlButton:@"↻" action:@selector(rotateClockwise)];
    up.tag = 4810;
    left.tag = 4811;
    reset.tag = 4812;
    right.tag = 4813;
    down.tag = 4814;
    rotate.tag = 4817;
    [self addSubview:up];
    [self addSubview:left];
    [self addSubview:reset];
    [self addSubview:right];
    [self addSubview:down];
    [self addSubview:rotate];

    UIButton *zoomOut = [self controlButton:@"−" action:@selector(zoomOut)];
    UIButton *zoomIn = [self controlButton:@"+" action:@selector(zoomIn)];
    zoomOut.tag = 4815;
    zoomIn.tag = 4816;
    [self addSubview:zoomOut];
    [self addSubview:zoomIn];

    _zoomLabel = [[UILabel alloc] init];
    _zoomLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.9];
    _zoomLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightSemibold];
    _zoomLabel.textAlignment = NSTextAlignmentCenter;
    [self addSubview:_zoomLabel];

    UIButton *mirrorButton = [self controlButton:@"Espejo: OFF" action:@selector(toggleMirror)];
    mirrorButton.tag = 4818;
    mirrorButton.titleLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
    mirrorButton.titleLabel.adjustsFontSizeToFitWidth = YES;
    [self addSubview:mirrorButton];

    UIButton *motionButton = [self controlButton:@"Movimiento: OFF" action:@selector(toggleMotion)];
    motionButton.tag = 4819;
    motionButton.titleLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
    motionButton.titleLabel.adjustsFontSizeToFitWidth = YES;
    [self addSubview:motionButton];

    [self refreshFraming];
    [self reloadPreview];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGFloat width = CGRectGetWidth(self.bounds);
    self.headerView.frame = CGRectMake(0, 0, width, 36);
    UILabel *title = [self.headerView viewWithTag:4802];
    title.frame = CGRectMake(14, 0, width - 60, 36);
    self.closeButton.frame = CGRectMake(width - 38, 1, 34, 34);

    CGFloat previewWidth = width - 28;
    self.previewContainer.frame = CGRectMake(14, 42, previewWidth, 108);
    self.previewImageView.frame = self.previewContainer.bounds;
    self.placeholderLabel.frame = self.previewContainer.bounds;

    CGFloat centerX = width * 0.5;
    CGFloat controlWidth = 36.0;
    CGFloat controlHeight = 28.0;
    [self viewWithTag:4810].frame = CGRectMake(centerX - controlWidth * 0.5, 156, controlWidth, controlHeight);
    [self viewWithTag:4811].frame = CGRectMake(centerX - 40 - controlWidth * 0.5, 188, controlWidth, controlHeight);
    [self viewWithTag:4812].frame = CGRectMake(centerX - controlWidth * 0.5, 188, controlWidth, controlHeight);
    [self viewWithTag:4813].frame = CGRectMake(centerX + 40 - controlWidth * 0.5, 188, controlWidth, controlHeight);
    [self viewWithTag:4814].frame = CGRectMake(centerX - controlWidth * 0.5, 220, controlWidth, controlHeight);
    [self viewWithTag:4817].frame = CGRectMake(centerX + 80 - controlWidth * 0.5, 188, controlWidth, controlHeight);

    [self viewWithTag:4815].frame = CGRectMake(centerX - 66, 258, 38, 27);
    self.zoomLabel.frame = CGRectMake(centerX - 25, 258, 50, 27);
    [self viewWithTag:4816].frame = CGRectMake(centerX + 28, 258, 38, 27);
    CGFloat toggleWidth = (width - 38.0) * 0.5;
    [self viewWithTag:4818].frame = CGRectMake(14, 292, toggleWidth, 27);
    [self viewWithTag:4819].frame = CGRectMake(24 + toggleWidth, 292, toggleWidth, 27);

    [self refreshFraming];
}

- (void)refreshFraming {
    self.zoomLabel.text = [NSString stringWithFormat:@"%.1fx", g_vcamZoom];
    UIButton *mirrorButton = (UIButton *)[self viewWithTag:4818];
    UIButton *motionButton = (UIButton *)[self viewWithTag:4819];
    [mirrorButton setTitle:(g_vcamMirrorEnabled ? @"Espejo: ON" : @"Espejo: OFF")
                  forState:UIControlStateNormal];
    [motionButton setTitle:(g_vcamMotionEnabled ? @"Movimiento: ON" : @"Movimiento: OFF")
                  forState:UIControlStateNormal];
    mirrorButton.backgroundColor = g_vcamMirrorEnabled
        ? [UIColor colorWithRed:0.12 green:0.42 blue:0.72 alpha:0.95]
        : [UIColor colorWithWhite:1.0 alpha:0.13];
    motionButton.backgroundColor = g_vcamMotionEnabled
        ? [UIColor colorWithRed:0.12 green:0.52 blue:0.34 alpha:0.95]
        : [UIColor colorWithWhite:1.0 alpha:0.13];

    UIImage *sourcePreview = self.sourcePreviewImage;
    if (!sourcePreview.CGImage || CGRectIsEmpty(self.previewContainer.bounds)) return;

    CGFloat renderScale = MAX(1.0, UIScreen.mainScreen.scale);
    CGFloat targetWidth = MAX(2.0, CGRectGetWidth(self.previewContainer.bounds) * renderScale);
    CGFloat targetHeight = MAX(2.0, CGRectGetHeight(self.previewContainer.bounds) * renderScale);
    CIImage *image = [CIImage imageWithCGImage:sourcePreview.CGImage];
    CGRect extent = image.extent;
    if (CGRectIsEmpty(extent) || extent.size.width <= 0.0 || extent.size.height <= 0.0) return;

    if (extent.origin.x != 0.0 || extent.origin.y != 0.0) {
        image = [image imageByApplyingTransform:
            CGAffineTransformMakeTranslation(-extent.origin.x, -extent.origin.y)];
        extent = image.extent;
    }

    NSInteger rotation = ((g_vcamRotationDegrees % 360) + 360) % 360;
    CGImagePropertyOrientation orientation = kCGImagePropertyOrientationUp;
    switch (rotation) {
        case 90: orientation = kCGImagePropertyOrientationRight; break;
        case 180: orientation = kCGImagePropertyOrientationDown; break;
        case 270: orientation = kCGImagePropertyOrientationLeft; break;
        default: break;
    }
    if (orientation != kCGImagePropertyOrientationUp) {
        image = [image imageByApplyingOrientation:orientation];
        extent = image.extent;
        if (!CGRectIsEmpty(extent) && (extent.origin.x != 0.0 || extent.origin.y != 0.0)) {
            image = [image imageByApplyingTransform:
                CGAffineTransformMakeTranslation(-extent.origin.x, -extent.origin.y)];
            extent = image.extent;
        }
    }

    // Mirror after rotation so selfie mode always flips the final camera view left-to-right.
    if (g_vcamMirrorEnabled) {
        image = [image imageByApplyingOrientation:kCGImagePropertyOrientationUpMirrored];
        extent = image.extent;
        if (!CGRectIsEmpty(extent) && (extent.origin.x != 0.0 || extent.origin.y != 0.0)) {
            image = [image imageByApplyingTransform:
                CGAffineTransformMakeTranslation(-extent.origin.x, -extent.origin.y)];
            extent = image.extent;
        }
    }

    CFTimeInterval motionTime = CACurrentMediaTime();
    CGFloat motionX = g_vcamMotionEnabled ? sin(motionTime * 0.72) * 0.0045 : 0.0;
    CGFloat motionY = g_vcamMotionEnabled ? cos(motionTime * 0.55) * 0.0035 : 0.0;
    CGFloat motionScale = g_vcamMotionEnabled
        ? 1.018 + sin(motionTime * 0.35) * 0.002
        : 1.0;
    CGFloat fillScale = MAX(targetWidth / extent.size.width,
                            targetHeight / extent.size.height);
    CGFloat scale = fillScale * g_vcamZoom * motionScale;
    image = [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];

    CGRect scaledExtent = image.extent;
    // Keep this identical to VCamMediaServerSource so the panel previews the real output.
    CGFloat translateX = ((targetWidth - scaledExtent.size.width) * 0.5)
        + (g_vcamOffsetX + motionX) * targetWidth;
    CGFloat translateY = ((targetHeight - scaledExtent.size.height) * 0.5)
        - (g_vcamOffsetY + motionY) * targetHeight;
    image = [image imageByApplyingTransform:
        CGAffineTransformMakeTranslation(translateX - scaledExtent.origin.x,
                                         translateY - scaledExtent.origin.y)];

    CGRect targetRect = CGRectMake(0, 0, targetWidth, targetHeight);
    image = [image imageByCroppingToRect:targetRect];
    CGImageRef renderedImage = [self.previewCIContext createCGImage:image fromRect:targetRect];
    if (!renderedImage) return;

    self.previewImageView.transform = CGAffineTransformIdentity;
    self.previewImageView.frame = self.previewContainer.bounds;
    self.previewImageView.image = [UIImage imageWithCGImage:renderedImage
                                                      scale:renderScale
                                                orientation:UIImageOrientationUp];
    CGImageRelease(renderedImage);
}

- (void)reloadPreview {
    NSString *path = [VCamSharedState sharedState].mediaPath;
    NSString *mediaType = [VCamSharedState sharedState].mediaType ?: @"";
    if (path.length == 0) {
        self.sourcePreviewImage = nil;
        self.previewImageView.image = nil;
        self.placeholderLabel.hidden = NO;
        [self refreshFraming];
        return;
    }

    self.sourcePreviewImage = nil;
    self.previewImageView.image = nil;
    self.placeholderLabel.text = [mediaType isEqualToString:@"video"]
        ? @"Preparando vista previa…"
        : @"Cargando imagen…";
    self.placeholderLabel.hidden = NO;

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            UIImage *preview = nil;
            if ([mediaType isEqualToString:@"image"]) {
                UIImage *sourcePreview = [UIImage imageWithContentsOfFile:path];
                if (sourcePreview) {
                    UIGraphicsBeginImageContextWithOptions(sourcePreview.size, NO, 1.0);
                    [sourcePreview drawInRect:CGRectMake(0, 0, sourcePreview.size.width, sourcePreview.size.height)];
                    preview = UIGraphicsGetImageFromCurrentImageContext();
                    UIGraphicsEndImageContext();
                }
            } else if ([mediaType isEqualToString:@"video"]) {
                AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
                AVAssetImageGenerator *generator = [[AVAssetImageGenerator alloc] initWithAsset:asset];
                generator.appliesPreferredTrackTransform = YES;
                generator.maximumSize = CGSizeMake(640, 360);
                NSError *error = nil;
                CGImageRef frame = [generator copyCGImageAtTime:CMTimeMakeWithSeconds(0.25, 600)
                                                     actualTime:NULL
                                                          error:&error];
                if (frame) {
                    preview = [UIImage imageWithCGImage:frame];
                    CGImageRelease(frame);
                } else if (error) {
                    NSLog(@"[VCam Pro] No se pudo generar la miniatura del vídeo: %@", error);
                }
            }

            if (preview && preview.imageOrientation != UIImageOrientationUp) {
                UIGraphicsBeginImageContextWithOptions(preview.size, NO, 1.0);
                [preview drawInRect:CGRectMake(0, 0, preview.size.width, preview.size.height)];
                UIImage *uprightPreview = UIGraphicsGetImageFromCurrentImageContext();
                UIGraphicsEndImageContext();
                if (uprightPreview) preview = uprightPreview;
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                VCamAdjustmentPanel *strongSelf = weakSelf;
                if (!strongSelf) return;
                NSString *currentPath = [VCamSharedState sharedState].mediaPath;
                if (![currentPath isEqualToString:path]) return;

                strongSelf.sourcePreviewImage = preview;
                strongSelf.previewImageView.image = nil;
                strongSelf.placeholderLabel.hidden = (preview != nil);
                strongSelf.placeholderLabel.text = preview
                    ? @""
                    : @"No se pudo generar la vista previa";
                [strongSelf setNeedsLayout];
                [strongSelf refreshFraming];
            });
        }
    });
}

- (void)publishTransform {
    g_vcamZoom = MAX(0.5, MIN(4.0, g_vcamZoom));
    g_vcamOffsetX = MAX(-1.0, MIN(1.0, g_vcamOffsetX));
    g_vcamOffsetY = MAX(-1.0, MIN(1.0, g_vcamOffsetY));
    [[VCamSharedState sharedState] setTransformWithZoom:g_vcamZoom
                                                 offsetX:g_vcamOffsetX
                                                 offsetY:g_vcamOffsetY
                                         rotationDegrees:g_vcamRotationDegrees];
    [self refreshFraming];
}

- (void)moveUp { g_vcamOffsetY -= 0.06; [self publishTransform]; }
- (void)moveDown { g_vcamOffsetY += 0.06; [self publishTransform]; }
- (void)moveLeft { g_vcamOffsetX -= 0.06; [self publishTransform]; }
- (void)moveRight { g_vcamOffsetX += 0.06; [self publishTransform]; }
- (void)zoomIn { g_vcamZoom += 0.1; [self publishTransform]; }
- (void)zoomOut { g_vcamZoom -= 0.1; [self publishTransform]; }
- (void)rotateClockwise { g_vcamRotationDegrees = (g_vcamRotationDegrees + 90) % 360; [self publishTransform]; }

- (void)toggleMirror {
    g_vcamMirrorEnabled = !g_vcamMirrorEnabled;
    [[VCamSharedState sharedState] setMirrorEnabled:g_vcamMirrorEnabled];
    [self refreshFraming];
}

- (void)toggleMotion {
    g_vcamMotionEnabled = !g_vcamMotionEnabled;
    [[VCamSharedState sharedState] setMotionEnabled:g_vcamMotionEnabled];
    [self refreshFraming];
}

- (void)resetTransform {
    g_vcamZoom = 1.0;
    g_vcamOffsetX = 0.0;
    g_vcamOffsetY = 0.0;
    g_vcamRotationDegrees = 0;
    [self publishTransform];
}

- (void)handlePanelPan:(UIPanGestureRecognizer *)gesture {
    UIView *container = self.superview;
    if (!container) return;

    CGPoint translation = [gesture translationInView:container];
    CGRect frame = self.frame;
    frame.origin.x += translation.x;
    frame.origin.y += translation.y;
    frame.origin.x = MAX(8.0, MIN(CGRectGetWidth(container.bounds) - CGRectGetWidth(frame) - 8.0, frame.origin.x));
    frame.origin.y = MAX(8.0, MIN(CGRectGetHeight(container.bounds) - CGRectGetHeight(frame) - 8.0, frame.origin.y));
    self.frame = frame;
    [gesture setTranslation:CGPointZero inView:container];
}

- (void)closeTapped {
    VCamCloseAdjustmentPanel();
}

@end

static void VCamCloseAdjustmentPanel(void) {
    if (!g_adjustmentPanel) return;
    if ([g_overlayWindow isKindOfClass:[VCamPassthroughWindow class]]) {
        ((VCamPassthroughWindow *)g_overlayWindow).interactivePanel = nil;
    }
    [g_adjustmentPanel removeFromSuperview];
    g_adjustmentPanel = nil;
    g_adjustmentPreviewRevision = -1;
}

static void VCamShowAdjustmentPanel(void) {
    if (!g_overlayController || !g_overlayWindow ||
        [UIApplication sharedApplication].applicationState != UIApplicationStateActive) return;

    if (g_adjustmentPanel) {
        [g_adjustmentPanel reloadPreview];
        [g_adjustmentPanel refreshFraming];
        return;
    }

    CGFloat width = MIN(244.0, CGRectGetWidth(g_overlayController.view.bounds) - 20.0);
    CGFloat height = 330.0;
    CGFloat x = MAX(10.0, CGRectGetWidth(g_overlayController.view.bounds) - width - 14.0);
    CGFloat y = MAX(50.0, CGRectGetHeight(g_overlayController.view.bounds) - height - 92.0);

    g_adjustmentPanel = [[VCamAdjustmentPanel alloc] initWithFrame:CGRectMake(x, y, width, height)];
    g_adjustmentPanel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
                                         UIViewAutoresizingFlexibleTopMargin;
    [g_overlayController.view addSubview:g_adjustmentPanel];
    if ([g_overlayWindow isKindOfClass:[VCamPassthroughWindow class]]) {
        ((VCamPassthroughWindow *)g_overlayWindow).interactivePanel = g_adjustmentPanel;
    }
    g_adjustmentPreviewRevision = [VCamSharedState sharedState].mediaRevision;
}

#pragma mark - Media Picker Delegate

static UIImage *VCamCreateOrientationNormalizedImage(UIImage *image) {
    if (!image) return nil;
    CGSize size = image.size;
    if (size.width <= 0.0 || size.height <= 0.0) return nil;

    UIGraphicsBeginImageContextWithOptions(size, NO, 1.0);
    [image drawInRect:CGRectMake(0, 0, size.width, size.height)];
    UIImage *normalized = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return normalized;
}

@interface VCamImagePickerDelegate : NSObject <UINavigationControllerDelegate, UIImagePickerControllerDelegate>
@end

@implementation VCamImagePickerDelegate

- (void)imagePickerController:(UIImagePickerController *)picker
 didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {

    NSURL *videoURL = info[UIImagePickerControllerMediaURL];
    if (videoURL) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *importError = nil;
            BOOL imported = [[VCamSharedState sharedState] importVideoAtURL:videoURL error:&importError];
            dispatch_async(dispatch_get_main_queue(), ^{
                [picker dismissViewControllerAnimated:YES completion:^{
                    if (imported) {
                        VCamRefreshFromServer();
                        if (g_adjustmentPanel) {
                            g_adjustmentPreviewRevision = [VCamSharedState sharedState].mediaRevision;
                            [g_adjustmentPanel reloadPreview];
                        }
                    } else {
                        NSLog(@"[VCam Pro] No se pudo importar el vídeo seleccionado: %@", importError);
                    }
                }];
            });
        });
        return;
    }

    UIImage *image = info[UIImagePickerControllerOriginalImage];
    if (!image) image = info[UIImagePickerControllerEditedImage];
    if (!image) {
        NSURL *imageURL = info[UIImagePickerControllerImageURL];
        if (imageURL) {
            BOOL didStartImageAccess = NO;
            if ([imageURL respondsToSelector:@selector(startAccessingSecurityScopedResource)]) {
                didStartImageAccess = [imageURL startAccessingSecurityScopedResource];
            }

            NSError *imageReadError = nil;
            NSData *imageData = [NSData dataWithContentsOfURL:imageURL
                                                       options:NSDataReadingMappedIfSafe
                                                         error:&imageReadError];
            if (imageData) {
                image = [UIImage imageWithData:imageData];
            } else {
                NSLog(@"[VCam Pro] No se pudo leer la imagen seleccionada: %@", imageReadError);
            }

            if (didStartImageAccess) {
                [imageURL stopAccessingSecurityScopedResource];
            }
        }
    }

    UIImage *normalizedImage = image ? VCamCreateOrientationNormalizedImage(image) : nil;
    if (!normalizedImage.CGImage) {
        NSLog(@"[VCam Pro] No se pudo obtener o convertir la imagen seleccionada.");
        [picker dismissViewControllerAnimated:YES completion:nil];
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *importError = nil;
        BOOL imported = [[VCamSharedState sharedState] importImage:normalizedImage error:&importError];
        dispatch_async(dispatch_get_main_queue(), ^{
            [picker dismissViewControllerAnimated:YES completion:^{
                if (imported) {
                    VCamRefreshFromServer();
                    if (g_adjustmentPanel) {
                        g_adjustmentPreviewRevision = [VCamSharedState sharedState].mediaRevision;
                        [g_adjustmentPanel reloadPreview];
                    }
                } else {
                    NSLog(@"[VCam Pro] No se pudo importar la imagen seleccionada: %@", importError);
                }
            }];
        });
    });
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

@end

#pragma mark - Button and Menu

static void VCamUpdateButton(void) {
    if (!g_floatButton) return;
    g_floatButton.backgroundColor = g_vcamEnabled
        ? [UIColor colorWithRed:0.10 green:0.66 blue:0.34 alpha:0.97]
        : [UIColor colorWithRed:0.20 green:0.22 blue:0.27 alpha:0.97];
    [g_floatButton setTitle:@"VC" forState:UIControlStateNormal];
    g_floatButton.accessibilityLabel = g_vcamEnabled ? @"VCam Pro activado" : @"VCam Pro desactivado";
}

static void VCamShowPicker(void) {
    if (!g_overlayController || g_overlayController.presentedViewController) return;
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.mediaTypes = @[@"public.image", @"public.movie"];
    picker.videoQuality = UIImagePickerControllerQualityTypeHigh;
    picker.delegate = g_pickerDelegate;
    [g_overlayController presentViewController:picker animated:YES completion:nil];
}

static NSString *VCamEngineStatusExplanation(NSString *status) {
    if ([status isEqualToString:@"not_reported"]) {
        return @"mediaserverd no ha confirmado que VCamMediaServer se haya cargado. La inyección del motor todavía no está confirmada.";
    }
    if ([status isEqualToString:@"loaded"]) {
        return @"VCamMediaServer se cargó en mediaserverd y está buscando la salida de cámara del sistema.";
    }
    if ([status isEqualToString:@"waiting_for_class"]) {
        return @"El motor está cargado, pero BWNodeOutput todavía no aparece en el proceso de cámara.";
    }
    if ([status isEqualToString:@"waiting_for_hook"]) {
        return @"BWNodeOutput existe, pero no se encontró un método emitSampleBuffer: compatible para interceptar.";
    }
    if ([status isEqualToString:@"hook_not_found"]) {
        return @"El motor se cargó, pero no pudo instalar el hook de salida de cámara.";
    }
    if ([status isEqualToString:@"hook_installed"]) {
        return @"El hook quedó instalado. Falta confirmar que recibe y sustituye fotogramas.";
    }
    if ([status isEqualToString:@"media_download_failed"]) {
        return @"El hook está activo, pero mediaserverd no pudo descargar el medio seleccionado desde SpringBoard.";
    }
    if ([status isEqualToString:@"media_decode_failed"]) {
        return @"El archivo llegó al motor, pero no se pudo decodificar o preparar.";
    }
    if ([status isEqualToString:@"media_loaded"]) {
        return @"El medio seleccionado ya está cargado en mediaserverd. Falta confirmar la sustitución de fotogramas.";
    }
    if ([status isEqualToString:@"hook_active_no_frame"]) {
        return @"El hook está recibiendo fotogramas de cámara, pero el motor todavía no consigue renderizar el medio virtual.";
    }
    if ([status isEqualToString:@"enabled"]) {
        return @"Cámara virtual activada. El motor debe continuar sustituyendo fotogramas.";
    }
    if ([status isEqualToString:@"disabled"]) {
        return @"Cámara virtual desactivada. El motor debe volver a entregar los fotogramas de la cámara física.";
    }
    if ([status isEqualToString:@"sample_buffer_create_failed"]) {
        return @"Los píxeles virtuales se generaron, pero CoreMedia no pudo crear una muestra compatible para la salida de cámara.";
    }
    if ([status isEqualToString:@"frames_replaced"]) {
        return @"VCam está sustituyendo fotogramas reales por el medio seleccionado.";
    }
    return @"El motor envió un estado desconocido. Revisa el detalle técnico que aparece abajo.";
}

static void VCamShowEngineDiagnostics(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSData *data = VCamHTTPGet(@"/state");
        NSDictionary *state = nil;
        if (data.length > 0) {
            NSError *error = nil;
            id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
            if ([object isKindOfClass:[NSDictionary class]]) state = (NSDictionary *)object;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (!g_overlayController || g_overlayController.presentedViewController) return;

            NSString *status = [state[@"engineStatus"] isKindOfClass:[NSString class]]
                ? state[@"engineStatus"] : @"not_reported";
            NSString *detail = [state[@"engineDetail"] isKindOfClass:[NSString class]]
                ? state[@"engineDetail"] : @"No se recibió respuesta del servidor de estado.";
            NSUInteger hooks = [state[@"engineHooks"] unsignedIntegerValue];
            NSUInteger frames = [state[@"engineFrames"] unsignedIntegerValue];
            NSString *orientation = [state[@"engineOrientationDiagnostic"] isKindOfClass:[NSString class]]
                ? state[@"engineOrientationDiagnostic"] : @"El motor aún no ha enviado datos de orientación.";

            NSString *message = state
                ? [NSString stringWithFormat:@"%@\n\nDetalle: %@\nHooks instalados: %lu\nFotogramas sustituidos: %lu\n\nÚLTIMO FOTOGRAMA / ORIENTACIÓN:\n%@",
                   VCamEngineStatusExplanation(status),
                   detail,
                   (unsigned long)hooks,
                   (unsigned long)frames,
                   orientation]
                : @"No se pudo consultar el estado compartido de VCam. El servidor de SpringBoard no respondió.";

            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Diagnóstico de VCam"
                                                                            message:message
                                                                     preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"Cerrar"
                                                      style:UIAlertActionStyleDefault
                                                    handler:nil]];
            [g_overlayController presentViewController:alert animated:YES completion:nil];
        });
    });
}

static NSString *VCamDeviceOrientationName(UIDeviceOrientation value) {
    switch (value) {
        case UIDeviceOrientationPortrait: return @"portrait";
        case UIDeviceOrientationPortraitUpsideDown: return @"portrait_upside_down";
        case UIDeviceOrientationLandscapeLeft: return @"landscape_left";
        case UIDeviceOrientationLandscapeRight: return @"landscape_right";
        case UIDeviceOrientationFaceUp: return @"face_up";
        case UIDeviceOrientationFaceDown: return @"face_down";
        default: return @"unknown_or_flat";
    }
}

static NSString *VCamInterfaceOrientationName(UIInterfaceOrientation value) {
    switch (value) {
        case UIInterfaceOrientationPortrait: return @"portrait";
        case UIInterfaceOrientationPortraitUpsideDown: return @"portrait_upside_down";
        case UIInterfaceOrientationLandscapeLeft: return @"landscape_left";
        case UIInterfaceOrientationLandscapeRight: return @"landscape_right";
        default: return @"unknown";
    }
}

static void VCamUpdateOrientationDiagnosticContext(void) {
    if (!g_isSpringBoardProcess) return;
    UIApplication *application = [UIApplication sharedApplication];
    UIDevice *device = [UIDevice currentDevice];
    UIInterfaceOrientation interfaceOrientation = UIInterfaceOrientationUnknown;
    NSString *sceneState = @"no_foreground_scene";
    NSString *statusBarHidden = @"unknown";
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in application.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            if (windowScene.activationState == UISceneActivationStateForegroundActive) {
                interfaceOrientation = windowScene.interfaceOrientation;
                if (windowScene.statusBarManager) {
                    statusBarHidden = windowScene.statusBarManager.statusBarHidden ? @"yes" : @"no";
                }
                sceneState = @"foreground_active";
                break;
            }
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (interfaceOrientation == UIInterfaceOrientationUnknown) {
        interfaceOrientation = application.statusBarOrientation;
    }
#pragma clang diagnostic pop
    NSDate *now = [NSDate date];
    NSString *timestamp = [NSString stringWithFormat:@"%.3f", now.timeIntervalSince1970];
    NSString *context = [NSString stringWithFormat:
        @"timestamp=%@ deviceOrientation=%@(%ld) interfaceOrientation=%@(%ld) scene=%@ appState=%ld statusBarHidden=%@",
        now,
        VCamDeviceOrientationName(device.orientation), (long)device.orientation,
        VCamInterfaceOrientationName(interfaceOrientation), (long)interfaceOrientation,
        sceneState, (long)application.applicationState, statusBarHidden];
    [[VCamSharedState sharedState] updateDiagnosticOrientationContext:context];

    NSInteger deviceValue = (NSInteger)device.orientation;
    NSInteger interfaceValue = (NSInteger)interfaceOrientation;
    BOOL deviceChanged = deviceValue != g_lastDiagnosticDeviceOrientation;
    BOOL interfaceChanged = interfaceValue != g_lastDiagnosticInterfaceOrientation;
    if (deviceChanged || interfaceChanged) {
        NSString *event = [NSString stringWithFormat:
            @"[VCam Pro/OrientationDiag] ORIENTATION_CHANGE timestamp=%@ uptime=%.3f device=%@(%ld)%@ interface=%@(%ld)%@ scene=%@ appState=%ld statusBarHidden=%@",
            timestamp,
            NSProcessInfo.processInfo.systemUptime,
            VCamDeviceOrientationName(device.orientation), (long)device.orientation,
            deviceChanged ? @" [changed]" : @"",
            VCamInterfaceOrientationName(interfaceOrientation), (long)interfaceOrientation,
            interfaceChanged ? @" [changed]" : @"",
            sceneState, (long)application.applicationState, statusBarHidden];
        [[VCamSharedState sharedState] appendDiagnosticOrientationEvent:event];
        g_lastDiagnosticDeviceOrientation = deviceValue;
        g_lastDiagnosticInterfaceOrientation = interfaceValue;
    }
}

static void VCamUpdateClientOrientationDiagnosticContext(void) {
    if (g_isSpringBoardProcess) return;

    UIApplication *application = [UIApplication sharedApplication];
    UIDevice *device = [UIDevice currentDevice];
    UIInterfaceOrientation interfaceOrientation = UIInterfaceOrientationUnknown;
    NSString *sceneState = @"no_foreground_scene";
    NSString *statusBarHidden = @"unknown";

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in application.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            if (windowScene.activationState == UISceneActivationStateForegroundActive) {
                interfaceOrientation = windowScene.interfaceOrientation;
                if (windowScene.statusBarManager) {
                    statusBarHidden = windowScene.statusBarManager.statusBarHidden ? @"yes" : @"no";
                }
                sceneState = @"foreground_active";
                break;
            }
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (interfaceOrientation == UIInterfaceOrientationUnknown) {
        interfaceOrientation = application.statusBarOrientation;
    }
#pragma clang diagnostic pop

    NSInteger deviceValue = (NSInteger)device.orientation;
    NSInteger interfaceValue = (NSInteger)interfaceOrientation;
    CFTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    BOOL changed = deviceValue != g_lastClientDeviceOrientation ||
                   interfaceValue != g_lastClientInterfaceOrientation;
    BOOL heartbeat = (now - g_lastClientOrientationDiagnosticTime) >= 0.8;
    if (!changed && !heartbeat) return;

    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"unknown.bundle";
    NSString *processName = NSProcessInfo.processInfo.processName ?: @"unknown-process";
    CGRect screenBounds = UIScreen.mainScreen.bounds;
    NSString *event = [NSString stringWithFormat:
        @"[VCam Pro/LiveDiag] CLIENT_ORIENTATION_CONTEXT timestamp=%.3f uptime=%.3f app=%@ process=%@ deviceOrientation=%@(%ld)%@ interfaceOrientation=%@(%ld)%@ scene=%@ appState=%ld statusBarHidden=%@ screen=%.0fx%.0f",
        [NSDate date].timeIntervalSince1970,
        now,
        bundleID,
        processName,
        VCamDeviceOrientationName(device.orientation), (long)device.orientation,
        deviceValue != g_lastClientDeviceOrientation ? @" [changed]" : @"",
        VCamInterfaceOrientationName(interfaceOrientation), (long)interfaceOrientation,
        interfaceValue != g_lastClientInterfaceOrientation ? @" [changed]" : @"",
        sceneState,
        (long)application.applicationState,
        statusBarHidden,
        screenBounds.size.width,
        screenBounds.size.height];
    VCamSendOrientationDiagnosticEvent(event);
    g_lastClientDeviceOrientation = deviceValue;
    g_lastClientInterfaceOrientation = interfaceValue;
    g_lastClientOrientationDiagnosticTime = now;
}

static void VCamStartOrientationDiagnosticSampler(void) {
    UIDevice *device = [UIDevice currentDevice];
    [device beginGeneratingDeviceOrientationNotifications];

    if (g_isSpringBoardProcess) {
        VCamUpdateOrientationDiagnosticContext();
    } else {
        VCamUpdateClientOrientationDiagnosticContext();
    }

    g_orientationDiagnosticTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                            dispatch_get_main_queue());
    dispatch_source_set_timer(g_orientationDiagnosticTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(0.25 * NSEC_PER_SEC),
                              (uint64_t)(0.05 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(g_orientationDiagnosticTimer, ^{
        if (g_isSpringBoardProcess) VCamUpdateOrientationDiagnosticContext();
        else VCamUpdateClientOrientationDiagnosticContext();
    });
    dispatch_resume(g_orientationDiagnosticTimer);
}

@interface VCamLiveDiagnosticsPanel : UIView
@property (nonatomic, strong) UIView *headerView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) UIButton *clipboardActionButton;
@property (nonatomic, strong) UIButton *clearButton;
@property (nonatomic, strong) UIButton *pauseButton;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) NSMutableString *logBuffer;
@property (nonatomic, assign) NSUInteger lastEventID;
@property (nonatomic, assign) BOOL paused;
@property (nonatomic, assign) BOOL pollInFlight;
@property (nonatomic, strong) dispatch_source_t pollTimer;
- (void)startLiveStream;
- (void)closePanel;
@end

@implementation VCamLiveDiagnosticsPanel

- (UIButton *)toolbarButton:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.96]
                 forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightBold];
    button.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    button.layer.cornerRadius = 8.0;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.10].CGColor;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.backgroundColor = [UIColor colorWithRed:0.025 green:0.035 blue:0.055 alpha:0.97];
    self.layer.cornerRadius = 15.0;
    self.layer.borderWidth = 1.0;
    self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.23].CGColor;
    self.layer.shadowColor = UIColor.blackColor.CGColor;
    self.layer.shadowOpacity = 0.42;
    self.layer.shadowRadius = 18.0;
    self.layer.shadowOffset = CGSizeMake(0, 7);
    self.clipsToBounds = NO;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    _logBuffer = [NSMutableString string];

    _headerView = [[UIView alloc] init];
    _headerView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.045];
    _headerView.layer.cornerRadius = 14.0;
    [self addSubview:_headerView];

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.text = @"VCAM  /  ORIENTACIÓN EN VIVO";
    _titleLabel.textColor = UIColor.whiteColor;
    _titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightHeavy];
    _titleLabel.adjustsFontSizeToFitWidth = YES;
    [_headerView addSubview:_titleLabel];

    _statusLabel = [[UILabel alloc] init];
    _statusLabel.text = @"INICIANDO FLUJO EN TIEMPO REAL…";
    _statusLabel.textColor = [UIColor colorWithRed:0.36 green:0.91 blue:0.66 alpha:1.0];
    _statusLabel.font = [UIFont monospacedDigitSystemFontOfSize:9 weight:UIFontWeightMedium];
    _statusLabel.adjustsFontSizeToFitWidth = YES;
    [_headerView addSubview:_statusLabel];

    _clipboardActionButton = [self toolbarButton:@"COPIAR" action:@selector(copyTapped)];
    _clearButton = [self toolbarButton:@"LIMPIAR" action:@selector(clearTapped)];
    _pauseButton = [self toolbarButton:@"PAUSA" action:@selector(pauseTapped)];
    _closeButton = [self toolbarButton:@"×" action:@selector(closePanel)];
    _closeButton.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightRegular];
    [_headerView addSubview:_clipboardActionButton];
    [_headerView addSubview:_clearButton];
    [_headerView addSubview:_pauseButton];
    [_headerView addSubview:_closeButton];

    UIPanGestureRecognizer *drag = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                            action:@selector(handlePanelDrag:)];
    drag.maximumNumberOfTouches = 1;
    drag.cancelsTouchesInView = NO;
    [_headerView addGestureRecognizer:drag];

    _logView = [[UITextView alloc] init];
    _logView.editable = NO;
    _logView.selectable = YES;
    _logView.alwaysBounceVertical = YES;
    _logView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    _logView.textColor = [UIColor colorWithRed:0.77 green:0.91 blue:0.84 alpha:1.0];
    _logView.font = [UIFont monospacedSystemFontOfSize:9.5 weight:UIFontWeightRegular];
    _logView.textContainerInset = UIEdgeInsetsMake(9, 8, 9, 8);
    _logView.layer.cornerRadius = 9.0;
    _logView.layer.borderWidth = 1.0;
    _logView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.08].CGColor;
    [self addSubview:_logView];

    [self appendLine:@"CONSOLA EN VIVO LISTA."];
    [self appendLine:@"Deja esta ventana abierta y entra en la app que muestra la imagen girada."];
    [self appendLine:@"Busca FRAME_RECEIVED, FRAME_DELIVERED, RENDER y CLIENT_CONNECTION."];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    self.headerView.frame = CGRectMake(0, 0, width, 79);
    self.titleLabel.frame = CGRectMake(12, 4, width - 24, 17);
    self.statusLabel.frame = CGRectMake(12, 21, width - 24, 14);

    // Keep all actions on a dedicated row so the copy button remains usable
    // even on compact iPhone widths.
    CGFloat actionY = 43.0;
    self.clipboardActionButton.frame = CGRectMake(10, actionY, 60, 29);
    self.clearButton.frame = CGRectMake(76, actionY, 58, 29);
    self.pauseButton.frame = CGRectMake(140, actionY, 58, 29);
    self.closeButton.frame = CGRectMake(width - 44, actionY, 34, 29);
    self.logView.frame = CGRectMake(9, 86, width - 18, MAX(80, height - 95));
}

- (void)setLiveStatus:(NSString *)status connected:(BOOL)connected {
    self.statusLabel.text = status ?: @"";
    self.statusLabel.textColor = connected
        ? [UIColor colorWithRed:0.36 green:0.91 blue:0.66 alpha:1.0]
        : [UIColor colorWithRed:1.0 green:0.67 blue:0.38 alpha:1.0];
}

- (void)appendLine:(NSString *)line {
    if (![line isKindOfClass:[NSString class]] || line.length == 0) return;
    NSString *time = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                     dateStyle:NSDateFormatterNoStyle
                                                     timeStyle:NSDateFormatterMediumStyle];
    [self.logBuffer appendFormat:@"[%@] %@\n", time, line];

    const NSUInteger maximumCharacters = 70000;
    if (self.logBuffer.length > maximumCharacters) {
        NSUInteger trimTo = self.logBuffer.length - maximumCharacters;
        NSRange newline = [self.logBuffer rangeOfString:@"\n"
                                                options:0
                                                  range:NSMakeRange(trimTo, self.logBuffer.length - trimTo)];
        if (newline.location != NSNotFound) {
            [self.logBuffer deleteCharactersInRange:NSMakeRange(0, NSMaxRange(newline))];
        } else {
            [self.logBuffer deleteCharactersInRange:NSMakeRange(0, trimTo)];
        }
    }

    self.logView.text = self.logBuffer;
    if (self.logView.text.length > 0) {
        NSRange end = NSMakeRange(self.logView.text.length - 1, 1);
        [self.logView scrollRangeToVisible:end];
    }
}

- (void)appendEventDictionaries:(NSArray *)events {
    for (id item in events) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *event = (NSDictionary *)item;
        NSUInteger eventID = [event[@"id"] unsignedIntegerValue];
        NSString *line = [event[@"line"] isKindOfClass:[NSString class]] ? event[@"line"] : nil;
        if (eventID > self.lastEventID) self.lastEventID = eventID;
        if (line.length > 0) [self appendLine:line];
    }
}

- (void)startLiveStream {
    self.paused = NO;
    [self setLiveStatus:@"CONECTANDO CON MEDIASERVERD / SPRINGBOARD…" connected:YES];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSData *data = VCamHTTPGet(@"/orientation-diagnostics?clear=1");
        NSDictionary *payload = nil;
        if (data.length > 0) {
            id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([object isKindOfClass:[NSDictionary class]]) payload = object;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.superview) return;
            if (payload) {
                strongSelf.lastEventID = 0;
                [strongSelf appendEventDictionaries:payload[@"events"]];
                [strongSelf setLiveStatus:@"EN VIVO · ESPERANDO FRAMES DE CÁMARA" connected:YES];
                [strongSelf startPollingTimer];
            } else {
                [strongSelf setLiveStatus:@"SIN CONEXIÓN CON SPRINGBOARD · REINTENTANDO" connected:NO];
                [strongSelf startPollingTimer];
            }
        });
    });
}

- (void)startPollingTimer {
    if (self.pollTimer) return;
    self.pollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                             dispatch_get_main_queue());
    dispatch_source_set_timer(self.pollTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                              (uint64_t)(0.25 * NSEC_PER_SEC),
                              (uint64_t)(0.05 * NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.pollTimer, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf pollLiveEvents];
    });
    dispatch_resume(self.pollTimer);
}

- (void)pollLiveEvents {
    if (self.paused || self.pollInFlight || !self.superview) return;
    self.pollInFlight = YES;
    NSUInteger afterID = self.lastEventID;
    NSString *path = [NSString stringWithFormat:@"/orientation-diagnostics?after=%lu",
                      (unsigned long)afterID];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSData *data = VCamHTTPGet(path);
        NSDictionary *payload = nil;
        if (data.length > 0) {
            id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([object isKindOfClass:[NSDictionary class]]) payload = object;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.pollInFlight = NO;
            if (!payload) {
                [strongSelf setLiveStatus:@"IPC SIN RESPUESTA · REINTENTANDO" connected:NO];
                return;
            }

            NSUInteger oldestID = [payload[@"oldestId"] unsignedIntegerValue];
            if (strongSelf.lastEventID > 0 && oldestID > strongSelf.lastEventID + 1) {
                [strongSelf appendLine:[NSString stringWithFormat:
                    @"AVISO: se descartaron eventos antiguos; el búfer conserva desde el ID %lu.",
                    (unsigned long)oldestID]];
            }
            [strongSelf appendEventDictionaries:payload[@"events"]];
            [strongSelf setLiveStatus:
                [NSString stringWithFormat:@"EN VIVO · ÚLTIMO EVENTO #%lu",
                 (unsigned long)strongSelf.lastEventID]
                                  connected:YES];
        });
    });
}

- (void)copyTapped {
    NSString *textToCopy = [self.logBuffer copy] ?: @"";
    if (textToCopy.length == 0) {
        [self setLiveStatus:@"NO HAY REGISTROS PARA COPIAR" connected:NO];
        return;
    }

    UIPasteboard.generalPasteboard.string = textToCopy;
    NSUInteger lineCount = [[textToCopy componentsSeparatedByString:@"\n"] count];
    [self setLiveStatus:
        [NSString stringWithFormat:@"COPIADO · %lu LÍNEAS · %lu CARACTERES",
         (unsigned long)lineCount,
         (unsigned long)textToCopy.length]
                 connected:YES];
}

- (void)clearTapped {
    self.logBuffer = [NSMutableString string];
    self.logView.text = @"";
    self.lastEventID = 0;
    self.paused = NO;
    [self.pauseButton setTitle:@"PAUSA" forState:UIControlStateNormal];
    [self setLiveStatus:@"LIMPIANDO SESIÓN…" connected:YES];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSData *data = VCamHTTPGet(@"/orientation-diagnostics?clear=1");
        NSDictionary *payload = nil;
        if (data.length > 0) {
            id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([object isKindOfClass:[NSDictionary class]]) payload = object;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (payload) {
                [strongSelf appendEventDictionaries:payload[@"events"]];
                [strongSelf setLiveStatus:@"SESIÓN LIMPIA · EN VIVO" connected:YES];
            } else {
                [strongSelf setLiveStatus:@"NO SE PUDO LIMPIAR IPC" connected:NO];
            }
        });
    });
}

- (void)pauseTapped {
    self.paused = !self.paused;
    [self.pauseButton setTitle:(self.paused ? @"SEGUIR" : @"PAUSA")
                      forState:UIControlStateNormal];
    [self setLiveStatus:(self.paused ? @"PAUSADO · LOS EVENTOS SIGUEN EN MEMORIA" : @"EN VIVO")
                 connected:!self.paused];
    if (!self.paused) [self pollLiveEvents];
}

- (void)handlePanelDrag:(UIPanGestureRecognizer *)gesture {
    UIView *container = self.superview;
    if (!container) return;
    CGPoint translation = [gesture translationInView:container];
    self.center = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
    [gesture setTranslation:CGPointZero inView:container];

    if (gesture.state == UIGestureRecognizerStateEnded ||
        gesture.state == UIGestureRecognizerStateCancelled) {
        CGFloat halfW = CGRectGetWidth(self.bounds) * 0.5;
        CGFloat halfH = CGRectGetHeight(self.bounds) * 0.5;
        self.center = CGPointMake(
            MAX(halfW, MIN(CGRectGetWidth(container.bounds) - halfW, self.center.x)),
            MAX(halfH + 20, MIN(CGRectGetHeight(container.bounds) - halfH, self.center.y)));
    }
}

- (void)closePanel {
    if (self.pollTimer) {
        dispatch_source_cancel(self.pollTimer);
        self.pollTimer = nil;
    }
    self.pollInFlight = NO;
    [self removeFromSuperview];
    if (g_overlayWindow && [g_overlayWindow isKindOfClass:[VCamPassthroughWindow class]]) {
        ((VCamPassthroughWindow *)g_overlayWindow).interactivePanel = nil;
    }
    if (g_liveDiagnosticsPanel == self) g_liveDiagnosticsPanel = nil;
}

@end

static void VCamShowOrientationDiagnostics(void) {
    if (!g_isSpringBoardProcess || !g_overlayController || !g_overlayWindow) return;
    if (g_liveDiagnosticsPanel && g_liveDiagnosticsPanel.superview) {
        [g_overlayController.view bringSubviewToFront:g_liveDiagnosticsPanel];
        return;
    }

    CGRect bounds = g_overlayController.view.bounds;
    CGFloat width = MIN(500.0, MAX(260.0, CGRectGetWidth(bounds) - 20.0));
    CGFloat height = MIN(560.0, MAX(220.0, CGRectGetHeight(bounds) - 115.0));
    CGFloat x = (CGRectGetWidth(bounds) - width) * 0.5;
    CGFloat y = MAX(52.0, MIN(94.0, CGRectGetHeight(bounds) * 0.10));
    VCamLiveDiagnosticsPanel *panel =
        [[VCamLiveDiagnosticsPanel alloc] initWithFrame:CGRectMake(x, y, width, height)];
    g_liveDiagnosticsPanel = panel;
    [g_overlayController.view addSubview:panel];
    [g_overlayController.view bringSubviewToFront:panel];
    if ([g_overlayWindow isKindOfClass:[VCamPassthroughWindow class]]) {
        ((VCamPassthroughWindow *)g_overlayWindow).interactivePanel = panel;
    }
    [panel startLiveStream];
}

static void VCamShowMenu(void) {
    if (!g_overlayController || g_overlayController.presentedViewController ||
        [UIApplication sharedApplication].applicationState != UIApplicationStateActive) return;

    NSString *message = [VCamSharedState sharedState].enabled ? @"Cámara virtual activada" : @"Cámara virtual desactivada";
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"VCam Pro"
                                                                  message:message
                                                           preferredStyle:UIAlertControllerStyleActionSheet];

    [menu addAction:[UIAlertAction actionWithTitle:@"Seleccionar foto o vídeo"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *action) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            VCamShowPicker();
        });
    }]];

    NSString *toggleTitle = [VCamSharedState sharedState].enabled ? @"Desactivar cámara virtual" : @"Activar cámara virtual";
    [menu addAction:[UIAlertAction actionWithTitle:toggleTitle
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *action) {
        BOOL nextEnabled = ![VCamSharedState sharedState].enabled;
        [[VCamSharedState sharedState] setEnabled:nextEnabled];
        VCamSetLocalEnabled(nextEnabled);
        VCamSetPreviewOverlaysVisible(nextEnabled);
        VCamUpdateButton();
        [[MediaManager sharedManager] setZoom:g_vcamZoom offsetX:g_vcamOffsetX offsetY:g_vcamOffsetY];
        [[MediaManager sharedManager] setRotationDegrees:g_vcamRotationDegrees];
        if (nextEnabled) [[MediaManager sharedManager] start];
        else [[MediaManager sharedManager] stop];
    }]];

    NSString *framingTitle = g_adjustmentPanel
        ? @"Cerrar vista previa y encuadre"
        : @"Vista previa y encuadre";
    [menu addAction:[UIAlertAction actionWithTitle:framingTitle
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *action) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (g_adjustmentPanel) VCamCloseAdjustmentPanel();
            else VCamShowAdjustmentPanel();
        });
    }]];

    NSString *liveDiagnosticsTitle = g_liveDiagnosticsPanel
        ? @"Cerrar consola de orientación en vivo"
        : @"Consola de orientación en vivo";
    [menu addAction:[UIAlertAction actionWithTitle:liveDiagnosticsTitle
                                             style:UIAlertActionStyleDefault
                                           handler:^(__unused UIAlertAction *action) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (g_liveDiagnosticsPanel) [g_liveDiagnosticsPanel closePanel];
            else VCamShowOrientationDiagnostics();
        });
    }]];

    [menu addAction:[UIAlertAction actionWithTitle:@"Comprobar motor de cámara"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *action) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            VCamShowEngineDiagnostics();
        });
    }]];

    [menu addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *popover = menu.popoverPresentationController;
    if (popover && g_floatButton) {
        popover.sourceView = g_floatButton;
        popover.sourceRect = g_floatButton.bounds;
    }
    [g_overlayController presentViewController:menu animated:YES completion:nil];
}

#pragma mark - Overlay Creation (Foreground Process Only)

static UIWindowScene *VCamActiveWindowScene(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
                return (UIWindowScene *)scene;
            }
        }
    }
    return nil;
}

static void VCamClampButton(void) {
    if (!g_floatButton || !g_overlayWindow) return;

    CGFloat width = CGRectGetWidth(g_overlayWindow.bounds);
    CGFloat height = CGRectGetHeight(g_overlayWindow.bounds);
    CGFloat x = MAX(kVCamButtonSize * 0.5 + kVCamButtonMargin,
                    MIN(width - kVCamButtonSize * 0.5 - kVCamButtonMargin, g_vcamButtonX * width));
    CGFloat y = MAX(kVCamButtonSize * 0.5 + kVCamButtonMargin,
                    MIN(height - kVCamButtonSize * 0.5 - kVCamButtonMargin, g_vcamButtonY * height));
    g_floatButton.center = CGPointMake(x, y);
}

static void VCamCreateOverlay(void) {
    // SpringBoard owns the only floating control. App processes only install
    // camera hooks and receive state/media over the local IPC channel.
    if (!g_isSpringBoardProcess) return;

    UIApplication *application = [UIApplication sharedApplication];
    if (application.applicationState != UIApplicationStateActive || !application.protectedDataAvailable) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ VCamCreateOverlay(); });
        return;
    }

    if (g_overlayWindow && g_floatButton) {
        g_overlayWindow.hidden = NO;
        VCamClampButton();
        VCamUpdateButton();
        return;
    }

    UIWindowScene *scene = VCamActiveWindowScene();
    VCamPassthroughWindow *window = nil;
    if (@available(iOS 13.0, *)) {
        if (scene) window = [[VCamPassthroughWindow alloc] initWithWindowScene:scene];
    }
    if (!window) window = [[VCamPassthroughWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];

    window.windowLevel = UIWindowLevelAlert - 1.0;
    window.backgroundColor = UIColor.clearColor;
    window.opaque = NO;
    window.userInteractionEnabled = YES;

    UIViewController *root = [[UIViewController alloc] init];
    root.view.backgroundColor = UIColor.clearColor;
    root.view.frame = window.bounds;
    root.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    VCamFloatButton *button = [VCamFloatButton buttonWithType:UIButtonTypeSystem];
    button.bounds = CGRectMake(0, 0, kVCamButtonSize, kVCamButtonSize);
    button.layer.cornerRadius = kVCamButtonSize * 0.5;
    button.layer.shadowColor = UIColor.blackColor.CGColor;
    button.layer.shadowOffset = CGSizeMake(0, 3);
    button.layer.shadowOpacity = 0.28;
    button.layer.shadowRadius = 5.0;
    button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:button action:@selector(handlePan:)];
    pan.maximumNumberOfTouches = 1;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:button action:@selector(handleTap:)];
    [tap requireGestureRecognizerToFail:pan];
    [button addGestureRecognizer:pan];
    [button addGestureRecognizer:tap];

    [root.view addSubview:button];
    window.rootViewController = root;
    window.vcamButton = button;

    g_overlayWindow = window;
    g_overlayController = root;
    g_floatButton = button;

    VCamClampButton();
    VCamUpdateButton();
    window.hidden = NO;
    NSLog(@"[VCam Pro] Interfaz flotante creada en proceso activo.");
}

#pragma mark - Lifecycle

static void VCamRegisterLifecycle(void) {
    if (g_lifecycleObservers) return;
    g_lifecycleObservers = [NSMutableArray array];
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];

    id active = [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        VCamRefreshFromServer();
        VCamCreateOverlay();
    }];
    [g_lifecycleObservers addObject:active];

    id resign = [center addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if (!g_isSpringBoardProcess) g_overlayWindow.hidden = YES;
        [[MediaManager sharedManager] stop];
    }];
    [g_lifecycleObservers addObject:resign];

    id background = [center addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if (!g_isSpringBoardProcess) g_overlayWindow.hidden = YES;
        [[MediaManager sharedManager] stop];
    }];
    [g_lifecycleObservers addObject:background];

    id lock = [center addObserverForName:UIApplicationProtectedDataWillBecomeUnavailable object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        g_overlayWindow.hidden = YES;
    }];
    [g_lifecycleObservers addObject:lock];

    id unlock = [center addObserverForName:UIApplicationProtectedDataDidBecomeAvailable object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        VCamRefreshFromServer();
        VCamCreateOverlay();
    }];
    [g_lifecycleObservers addObject:unlock];

    id orientation = [center addObserverForName:UIDeviceOrientationDidChangeNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        VCamClampButton();
    }];
    [g_lifecycleObservers addObject:orientation];
}

#pragma mark - Constructor

%ctor {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        g_isSpringBoardProcess = [bundleID isEqualToString:@"com.apple.springboard"];
        g_syncQueue = dispatch_queue_create("com.vcam.pro.state.sync", DISPATCH_QUEUE_SERIAL);

        %init;
        VCamRegisterIPCObserver();
        g_pickerDelegate = [[VCamImagePickerDelegate alloc] init];

        if (g_isSpringBoardProcess) {
            [[VCamSharedState sharedState] startServer];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            VCamStartOrientationDiagnosticSampler();
            VCamRegisterLifecycle();
            VCamRefreshFromServer();

            if (!g_isSpringBoardProcess) {
                NSString *event = [NSString stringWithFormat:
                    @"[VCam Pro/OrientationDiag] CLIENT_TWEAK_LOADED timestamp=%.3f uptime=%.3f",
                    [NSDate date].timeIntervalSince1970,
                    NSProcessInfo.processInfo.systemUptime];
                VCamSendOrientationDiagnosticEvent(event);
            }

            if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    VCamCreateOverlay();
                });
            }
        });
    }
}
