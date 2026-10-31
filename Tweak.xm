#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>
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
static BOOL g_vcamEnabled = NO;
static CGFloat g_vcamZoom = 1.0;
static CGFloat g_vcamOffsetX = 0.0;
static CGFloat g_vcamOffsetY = 0.0;
static CGFloat g_vcamButtonX = 0.92;
static CGFloat g_vcamButtonY = 0.24;
static NSInteger g_lastMediaRevision = -1;
static NSInteger g_loadingMediaRevision = -1;
static dispatch_queue_t g_syncQueue;
static UIWindow *g_overlayWindow = nil;
static UIViewController *g_overlayController = nil;
static UIButton *g_floatButton = nil;
static id g_pickerDelegate = nil;
static NSMutableArray *g_lifecycleObservers = nil;
static char g_darwinObserverToken;
static const void *kVCamDelegateProxyKey = &kVCamDelegateProxyKey;
static NSUInteger g_vcamVideoCallbackCount = 0;
static NSUInteger g_vcamVideoReplacementCount = 0;

static void VCamRefreshFromServer(void);
static void VCamCreateOverlay(void);
static void VCamShowMenu(void);
static void VCamUpdateButton(void);
static BOOL VCamIsEnabled(void);
static void VCamPostControlAsync(NSDictionary *control);
static void VCamClampButton(void);

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

static BOOL VCamReadHTTPStatus(int socketFD, NSInteger *statusCode) {
    NSMutableData *headers = [NSMutableData data];
    NSData *separator = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t buffer[4096];
    NSRange range = NSMakeRange(NSNotFound, 0);

    while (range.location == NSNotFound && headers.length <= 16 * 1024) {
        ssize_t amount = recv(socketFD, buffer, sizeof(buffer), 0);
        if (amount < 0) {
            if (errno == EINTR) continue;
            return NO;
        }
        if (amount == 0) return NO;
        [headers appendBytes:buffer length:(NSUInteger)amount];
        range = [headers rangeOfData:separator options:0 range:NSMakeRange(0, headers.length)];
    }

    if (range.location == NSNotFound) return NO;
    NSData *headerData = [headers subdataWithRange:NSMakeRange(0, range.location)];
    NSString *headerText = [[NSString alloc] initWithData:headerData encoding:NSUTF8StringEncoding];
    if (!headerText.length) return NO;

    NSString *firstLine = [[headerText componentsSeparatedByString:@"\r\n"] firstObject];
    NSArray<NSString *> *parts = [firstLine componentsSeparatedByString:@" "];
    if (parts.count < 2) return NO;

    NSInteger code = parts[1].integerValue;
    if (statusCode) *statusCode = code;
    return code >= 200 && code < 300;
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

static BOOL VCamHTTPPostJSON(NSString *path, NSDictionary *dictionary) {
    NSError *error = nil;
    NSData *body = [NSJSONSerialization dataWithJSONObject:dictionary options:0 error:&error];
    if (!body) {
        NSLog(@"[VCam Pro] No se pudo serializar control: %@", error);
        return NO;
    }

    int socketFD = VCamConnectToServer();
    if (socketFD < 0) return NO;

    NSString *header = [NSString stringWithFormat:@"POST %@ HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n", path, (unsigned long)body.length];
    BOOL sent = VCamSocketSendAll(socketFD, header.UTF8String, header.length) &&
                VCamSocketSendAll(socketFD, body.bytes, body.length);
    NSInteger status = 0;
    BOOL success = sent && VCamReadHTTPStatus(socketFD, &status);
    close(socketFD);
    if (!success) NSLog(@"[VCam Pro] Control IPC fallido (HTTP %ld).", (long)status);
    return success;
}

static BOOL VCamHTTPUploadFile(NSString *filePath, NSString *mediaType, NSString *extension) {
    struct stat fileInfo;
    if (stat(filePath.fileSystemRepresentation, &fileInfo) != 0 || fileInfo.st_size <= 0) return NO;
    if ((unsigned long long)fileInfo.st_size > 1024ULL * 1024ULL * 1024ULL) return NO;

    NSString *safeExtension = extension.lowercaseString;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789"];
    safeExtension = [[safeExtension componentsSeparatedByCharactersInSet:allowed.invertedSet] componentsJoinedByString:@""];
    if (safeExtension.length == 0 || safeExtension.length > 8) safeExtension = [mediaType isEqualToString:@"image"] ? @"jpg" : @"mp4";

    int fileFD = open(filePath.fileSystemRepresentation, O_RDONLY);
    if (fileFD < 0) return NO;

    int socketFD = VCamConnectToServer();
    if (socketFD < 0) {
        close(fileFD);
        return NO;
    }

    NSString *path = [NSString stringWithFormat:@"/upload?type=%@&ext=%@", mediaType, safeExtension];
    NSString *header = [NSString stringWithFormat:@"POST %@ HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/octet-stream\r\nContent-Length: %lld\r\nConnection: close\r\n\r\n", path, (long long)fileInfo.st_size];
    BOOL success = VCamSocketSendAll(socketFD, header.UTF8String, header.length);

    uint8_t buffer[64 * 1024];
    unsigned long long remaining = (unsigned long long)fileInfo.st_size;
    while (success && remaining > 0) {
        ssize_t amount = read(fileFD, buffer, (size_t)MIN((unsigned long long)sizeof(buffer), remaining));
        if (amount < 0) {
            if (errno == EINTR) continue;
            success = NO;
            break;
        }
        if (amount == 0) {
            success = NO;
            break;
        }
        success = VCamSocketSendAll(socketFD, buffer, (size_t)amount);
        remaining -= (unsigned long long)amount;
    }

    close(fileFD);
    NSInteger status = 0;
    if (success) success = VCamReadHTTPStatus(socketFD, &status);
    close(socketFD);
    if (!success) NSLog(@"[VCam Pro] Subida IPC fallida (HTTP %ld).", (long)status);
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
    if (!VCamHTTPDownloadToFile(@"/media", path)) {
        NSLog(@"[VCam Pro] No se pudo descargar el medio compartido desde SpringBoard.");
        return nil;
    }
    return path;
}

static void VCamPostControlAsync(NSDictionary *control) {
    if (![control isKindOfClass:[NSDictionary class]] || control.count == 0) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (VCamHTTPPostJSON(@"/control", control)) VCamRefreshFromServer();
    });
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
        CGFloat buttonX = [state[@"buttonX"] doubleValue];
        CGFloat buttonY = [state[@"buttonY"] doubleValue];

        VCamSetLocalEnabled(enabled);
        g_vcamZoom = MAX(0.5, MIN(4.0, zoom));
        g_vcamOffsetX = MAX(-1.0, MIN(1.0, offsetX));
        g_vcamOffsetY = MAX(-1.0, MIN(1.0, offsetY));
        g_vcamButtonX = MAX(0.04, MIN(0.96, buttonX));
        g_vcamButtonY = MAX(0.04, MIN(0.96, buttonY));

        dispatch_async(dispatch_get_main_queue(), ^{
            VCamUpdateButton();
            VCamClampButton();
        });

        if (g_isSpringBoardProcess) return;

        UIApplication *application = [UIApplication sharedApplication];
        if (application.applicationState != UIApplicationStateActive) return;

        MediaManager *manager = [MediaManager sharedManager];
        [manager setZoom:g_vcamZoom offsetX:g_vcamOffsetX offsetY:g_vcamOffsetY];

        if (!enabled) {
            [manager stop];
            NSLog(@"[VCam Pro] Estado remoto desactivado (rev %ld).", (long)stateRevision);
        } else if (mediaRevision > 0 && mediaRevision != g_lastMediaRevision && mediaRevision != g_loadingMediaRevision) {
            g_loadingMediaRevision = mediaRevision;
            NSString *extension = [state[@"mediaExtension"] isKindOfClass:[NSString class]] ? state[@"mediaExtension"] : @"mp4";
            NSString *mediaType = [state[@"mediaType"] isKindOfClass:[NSString class]] ? state[@"mediaType"] : @"video";
            NSString *localPath = VCamDownloadCurrentMedia(extension, mediaRevision);
            if (!localPath) {
                g_loadingMediaRevision = -1;
                VCamSetLocalEnabled(NO);
                return;
            }

            NSURL *localURL = [NSURL fileURLWithPath:localPath];
            [manager stop];
            [manager loadMediaFromURL:localURL mediaType:mediaType completion:^(BOOL success, NSError *error) {
                g_loadingMediaRevision = -1;
                if (success && VCamIsEnabled()) {
                    g_lastMediaRevision = mediaRevision;
                    [manager setZoom:g_vcamZoom offsetX:g_vcamOffsetX offsetY:g_vcamOffsetY];
                    [manager start];
                    NSLog(@"[VCam Pro] Medio remoto listo en %@ (rev %ld).", [[NSBundle mainBundle] bundleIdentifier], (long)mediaRevision);
                } else {
                    VCamSetLocalEnabled(NO);
                    NSLog(@"[VCam Pro] No se pudo preparar el medio remoto: %@", error);
                }
            }];
        } else if (enabled) {
            if (manager.isReady) [manager start];
            else NSLog(@"[VCam Pro] VCam está activado pero este proceso aún no tiene medio cargado.");
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

    id<AVCaptureVideoDataOutputSampleBufferDelegate> delegate = self.originalDelegate;
    if (!delegate) {
        NSLog(@"[VCam Pro] El delegado original de AVCaptureVideoDataOutput ya no existe.");
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
        NSLog(@"[VCam Pro] AVCaptureVideoDataOutput callback #%lu; replacements=%lu; enabled=%d; ready=%d; app=%@",
              (unsigned long)callbackNumber,
              (unsigned long)replacementCount,
              VCamIsEnabled(),
              [MediaManager sharedManager].isReady,
              [[NSBundle mainBundle] bundleIdentifier]);
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
    NSLog(@"[VCam Pro] Delegate de vídeo interceptado; formato solicitado=%@; app=%@",
          format ?: @"default",
          [[NSBundle mainBundle] bundleIdentifier]);
    %orig(proxy, queue);
}

%end

#pragma mark - Still Photo Result Hook

static BOOL VCamIsJPEGData(NSData *data) {
    if (data.length < 3) return NO;
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    return bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF;
}

%hook AVCapturePhoto

- (NSData *)fileDataRepresentation {
    // Primero obtenemos el resultado original para conservar intactos HEIC,
    // RAW u otros contenedores que este reemplazo JPEG no puede reproducir.
    NSData *original = %orig;
    if (!VCamIsEnabled() || ![MediaManager sharedManager].isReady) return original;
    if (!VCamIsJPEGData(original)) return original;

    NSData *replacement = [[MediaManager sharedManager] nextPhotoData];
    if (replacement.length > 0 && VCamIsJPEGData(replacement)) {
        NSLog(@"[VCam Pro] AVCapturePhoto JPEG sustituido por imagen virtual.");
        return replacement;
    }
    return original;
}

%end

// Compatibilidad con aplicaciones antiguas que convierten capturas JPEG
// mediante AVCaptureStillImageOutput en lugar de AVCapturePhotoOutput.
%hook AVCaptureStillImageOutput

+ (NSData *)jpegStillImageNSDataRepresentation:(CMSampleBufferRef)jpegSampleBuffer {
    if (VCamIsEnabled() && [MediaManager sharedManager].isReady) {
        NSData *replacement = [[MediaManager sharedManager] nextPhotoData];
        if (replacement.length > 0) {
            NSLog(@"[VCam Pro] Conversión JPEG de AVCaptureStillImageOutput sustituida.");
            return replacement;
        }
    }
    return %orig(jpegSampleBuffer);
}

%end

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
            VCamPostControlAsync(@{@"buttonX": @(g_vcamButtonX), @"buttonY": @(g_vcamButtonY)});
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
@end

@implementation VCamPassthroughWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || self.alpha < 0.01 || !self.userInteractionEnabled) return nil;

    UIView *hit = [super hitTest:point withEvent:event];
    if (!hit) return nil;

    if (self.rootViewController.presentedViewController) return hit;

    UIButton *button = self.vcamButton;
    if (button && (hit == button || [hit isDescendantOfView:button])) return hit;
    return nil;
}

@end

#pragma mark - Image Adjustment Panel

@interface VCamAdjustmentViewController : UIViewController
- (void)moveUp;
- (void)moveDown;
- (void)moveLeft;
- (void)moveRight;
- (void)zoomIn;
- (void)zoomOut;
- (void)resetTransform;
- (void)publishTransform;
- (void)closePanel;
@end

@implementation VCamAdjustmentViewController

- (UIButton *)controlButton:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:23 weight:UIFontWeightSemibold];
    button.backgroundColor = [UIColor secondarySystemBackgroundColor];
    button.layer.cornerRadius = 12.0;
    [button.widthAnchor constraintEqualToConstant:64].active = YES;
    [button.heightAnchor constraintEqualToConstant:54].active = YES;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"Ajustar imagen";

    UILabel *description = [[UILabel alloc] init];
    description.text = @"Mueve la imagen y ajusta el zoom de la cámara virtual.";
    description.font = [UIFont systemFontOfSize:14];
    description.textColor = [UIColor secondaryLabelColor];
    description.textAlignment = NSTextAlignmentCenter;
    description.numberOfLines = 0;

    UIButton *up = [self controlButton:@"↑" action:@selector(moveUp)];
    UIButton *left = [self controlButton:@"←" action:@selector(moveLeft)];
    UIButton *center = [self controlButton:@"•" action:@selector(resetTransform)];
    UIButton *right = [self controlButton:@"→" action:@selector(moveRight)];
    UIButton *down = [self controlButton:@"↓" action:@selector(moveDown)];

    UIStackView *row1 = [[UIStackView alloc] initWithArrangedSubviews:@[up]];
    UIStackView *row2 = [[UIStackView alloc] initWithArrangedSubviews:@[left, center, right]];
    UIStackView *row3 = [[UIStackView alloc] initWithArrangedSubviews:@[down]];
    row1.alignment = row2.alignment = row3.alignment = UIStackViewAlignmentCenter;
    row1.distribution = row2.distribution = row3.distribution = UIStackViewDistributionEqualSpacing;
    row1.spacing = row2.spacing = row3.spacing = 14;

    UIButton *zoomOut = [self controlButton:@"−" action:@selector(zoomOut)];
    UIButton *zoomIn = [self controlButton:@"+" action:@selector(zoomIn)];
    UILabel *zoomLabel = [[UILabel alloc] init];
    zoomLabel.text = [NSString stringWithFormat:@"Zoom %.1fx", g_vcamZoom];
    zoomLabel.font = [UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightSemibold];
    zoomLabel.textAlignment = NSTextAlignmentCenter;
    zoomLabel.tag = 4801;
    UIStackView *zoomRow = [[UIStackView alloc] initWithArrangedSubviews:@[zoomOut, zoomLabel, zoomIn]];
    zoomRow.alignment = UIStackViewAlignmentCenter;
    zoomRow.distribution = UIStackViewDistributionEqualSpacing;
    zoomRow.spacing = 18;

    UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
    [done setTitle:@"Listo" forState:UIControlStateNormal];
    done.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [done addTarget:self action:@selector(closePanel) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[description, row1, row2, row3, zoomRow, done]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.distribution = UIStackViewDistributionEqualSpacing;
    stack.spacing = 18;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [stack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [description.widthAnchor constraintEqualToAnchor:stack.widthAnchor]
    ]];
}

- (void)publishTransform {
    g_vcamZoom = MAX(0.5, MIN(4.0, g_vcamZoom));
    g_vcamOffsetX = MAX(-1.0, MIN(1.0, g_vcamOffsetX));
    g_vcamOffsetY = MAX(-1.0, MIN(1.0, g_vcamOffsetY));
    [[MediaManager sharedManager] setZoom:g_vcamZoom offsetX:g_vcamOffsetX offsetY:g_vcamOffsetY];
    VCamPostControlAsync(@{@"zoom": @(g_vcamZoom), @"offsetX": @(g_vcamOffsetX), @"offsetY": @(g_vcamOffsetY)});
    UILabel *label = [self.view viewWithTag:4801];
    label.text = [NSString stringWithFormat:@"Zoom %.1fx", g_vcamZoom];
}

- (void)moveUp { g_vcamOffsetY -= 0.06; [self publishTransform]; }
- (void)moveDown { g_vcamOffsetY += 0.06; [self publishTransform]; }
- (void)moveLeft { g_vcamOffsetX -= 0.06; [self publishTransform]; }
- (void)moveRight { g_vcamOffsetX += 0.06; [self publishTransform]; }

- (void)zoomIn { g_vcamZoom += 0.1; [self publishTransform]; }
- (void)zoomOut { g_vcamZoom -= 0.1; [self publishTransform]; }

- (void)resetTransform {
    g_vcamZoom = 1.0;
    g_vcamOffsetX = 0.0;
    g_vcamOffsetY = 0.0;
    [self publishTransform];
}

- (void)closePanel {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

#pragma mark - Media Picker Delegate

@interface VCamImagePickerDelegate : NSObject <UINavigationControllerDelegate, UIImagePickerControllerDelegate>
@end

@implementation VCamImagePickerDelegate

- (void)imagePickerController:(UIImagePickerController *)picker
 didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {

    NSURL *videoURL = info[UIImagePickerControllerMediaURL];
    if (videoURL) {
        BOOL didStartAccess = NO;
        if ([videoURL respondsToSelector:@selector(startAccessingSecurityScopedResource)]) {
            didStartAccess = [videoURL startAccessingSecurityScopedResource];
        }
        NSString *path = videoURL.path;
        NSString *extension = videoURL.pathExtension.length ? videoURL.pathExtension : @"mp4";

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            BOOL uploaded = VCamHTTPUploadFile(path, @"video", extension);
            if (didStartAccess) [videoURL stopAccessingSecurityScopedResource];
            dispatch_async(dispatch_get_main_queue(), ^{
                [picker dismissViewControllerAnimated:YES completion:^{
                    if (uploaded) VCamRefreshFromServer();
                    else NSLog(@"[VCam Pro] No se pudo enviar el vídeo al proceso central.");
                }];
            });
        });
        return;
    }

    UIImage *image = info[UIImagePickerControllerOriginalImage];
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

    NSData *jpeg = image ? UIImageJPEGRepresentation(image, 0.94) : nil;
    if (!jpeg) {
        NSLog(@"[VCam Pro] No se pudo obtener o convertir la imagen seleccionada.");
        [picker dismissViewControllerAnimated:YES completion:nil];
        return;
    }

    NSString *temporaryPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"vcam_upload_%@.jpg", NSUUID.UUID.UUIDString]];
    NSError *writeError = nil;
    if (![jpeg writeToFile:temporaryPath options:NSDataWritingAtomic error:&writeError]) {
        NSLog(@"[VCam Pro] No se pudo guardar temporalmente la imagen: %@", writeError);
        [picker dismissViewControllerAnimated:YES completion:nil];
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL uploaded = VCamHTTPUploadFile(temporaryPath, @"image", @"jpg");
        unlink(temporaryPath.fileSystemRepresentation);
        dispatch_async(dispatch_get_main_queue(), ^{
            [picker dismissViewControllerAnimated:YES completion:^{
                if (uploaded) VCamRefreshFromServer();
                else NSLog(@"[VCam Pro] No se pudo enviar la imagen al proceso central.");
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

static void VCamShowMenu(void) {
    if (!g_overlayController || g_overlayController.presentedViewController ||
        [UIApplication sharedApplication].applicationState != UIApplicationStateActive) return;

    NSString *message = g_vcamEnabled ? @"Cámara virtual activada" : @"Cámara virtual desactivada";
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

    NSString *toggleTitle = g_vcamEnabled ? @"Desactivar cámara virtual" : @"Activar cámara virtual";
    [menu addAction:[UIAlertAction actionWithTitle:toggleTitle
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *action) {
        g_vcamEnabled = !g_vcamEnabled;
        VCamUpdateButton();
        [[MediaManager sharedManager] setZoom:g_vcamZoom offsetX:g_vcamOffsetX offsetY:g_vcamOffsetY];
        if (g_vcamEnabled) [[MediaManager sharedManager] start];
        else [[MediaManager sharedManager] stop];
        VCamPostControlAsync(@{@"enabled": @(g_vcamEnabled)});
    }]];

    [menu addAction:[UIAlertAction actionWithTitle:@"Posición y zoom"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *action) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            VCamAdjustmentViewController *controller = [[VCamAdjustmentViewController alloc] init];
            controller.modalPresentationStyle = UIModalPresentationFormSheet;
            [g_overlayController presentViewController:controller animated:YES completion:nil];
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
    NSLog(@"[VCam Pro] Interfaz flotante creada en proceso activo: %@", [[NSBundle mainBundle] bundleIdentifier]);
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
        g_overlayWindow.hidden = YES;
        [[MediaManager sharedManager] stop];
    }];
    [g_lifecycleObservers addObject:resign];

    id background = [center addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        g_overlayWindow.hidden = YES;
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
            VCamRegisterLifecycle();
            VCamRefreshFromServer();

            if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    VCamCreateOverlay();
                });
            }
        });
    }
}
