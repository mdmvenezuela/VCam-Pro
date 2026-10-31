#import "VCamMediaServerSource.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <CoreMedia/CoreMedia.h>
#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <math.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <unistd.h>
#import <string.h>

static const uint16_t kVCamMediaServerPort = 47831;
static NSString * const kVCamSystemReplacementAttachment =
    @"com.vcam.pro.systemreplacement.v1";

static BOOL VCMWriteAll(int fd, const void *bytes, size_t length) {
    const uint8_t *cursor = (const uint8_t *)bytes;
    size_t offset = 0;
    while (offset < length) {
        ssize_t amount = write(fd, cursor + offset, length - offset);
        if (amount < 0) {
            if (errno == EINTR) continue;
            return NO;
        }
        if (amount == 0) return NO;
        offset += (size_t)amount;
    }
    return YES;
}

static BOOL VCMReadAll(int fd, void *bytes, size_t length) {
    uint8_t *cursor = (uint8_t *)bytes;
    size_t offset = 0;
    while (offset < length) {
        ssize_t amount = recv(fd, cursor + offset, length - offset, 0);
        if (amount < 0) {
            if (errno == EINTR) continue;
            return NO;
        }
        if (amount == 0) return NO;
        offset += (size_t)amount;
    }
    return YES;
}

static int VCMOpenLocalRequest(NSString *path,
                               NSInteger *statusCode,
                               unsigned long long *contentLength,
                               NSMutableData **initialBody) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    int noSignal = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal));

    struct timeval timeout;
    timeout.tv_sec = 20;
    timeout.tv_usec = 0;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_port = htons(kVCamMediaServerPort);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(fd);
        return -1;
    }

    NSString *request = [NSString stringWithFormat:
        @"GET %@ HTTP/1.1\r\nHost: 127.0.0.1\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n",
        path];
    if (!VCMWriteAll(fd, request.UTF8String, request.length)) {
        close(fd);
        return -1;
    }

    NSMutableData *received = [NSMutableData data];
    NSData *separator = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t buffer[8192];
    NSRange headerRange = NSMakeRange(NSNotFound, 0);

    while (headerRange.location == NSNotFound && received.length <= 32 * 1024) {
        ssize_t amount = recv(fd, buffer, sizeof(buffer), 0);
        if (amount < 0) {
            if (errno == EINTR) continue;
            close(fd);
            return -1;
        }
        if (amount == 0) {
            close(fd);
            return -1;
        }
        [received appendBytes:buffer length:(NSUInteger)amount];
        headerRange = [received rangeOfData:separator
                                    options:0
                                      range:NSMakeRange(0, received.length)];
    }

    if (headerRange.location == NSNotFound) {
        close(fd);
        return -1;
    }

    NSData *headerData = [received subdataWithRange:NSMakeRange(0, headerRange.location)];
    NSString *headerText = [[NSString alloc] initWithData:headerData
                                                 encoding:NSUTF8StringEncoding];
    if (!headerText) {
        close(fd);
        return -1;
    }

    NSArray<NSString *> *headerLines = [headerText componentsSeparatedByString:@"\r\n"];
    NSArray<NSString *> *statusParts = headerLines.firstObject
        ? [headerLines.firstObject componentsSeparatedByString:@" "] : @[];
    if (statusParts.count < 2) {
        close(fd);
        return -1;
    }

    NSInteger parsedStatus = statusParts[1].integerValue;
    unsigned long long parsedLength = ULLONG_MAX;
    for (NSUInteger index = 1; index < headerLines.count; index++) {
        NSString *line = headerLines[index];
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        NSString *key = [[[line substringToIndex:colon.location]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] lowercaseString];
        NSString *value = [[line substringFromIndex:colon.location + 1]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([key isEqualToString:@"content-length"]) {
            const char *text = value.UTF8String;
            char *end = NULL;
            errno = 0;
            unsigned long long number = strtoull(text, &end, 10);
            if (errno == 0 && end && *end == '\0') parsedLength = number;
        }
    }

    NSUInteger bodyOffset = NSMaxRange(headerRange);
    NSMutableData *body = [NSMutableData data];
    if (received.length > bodyOffset) {
        [body appendBytes:(const uint8_t *)received.bytes + bodyOffset
                   length:received.length - bodyOffset];
    }

    if (statusCode) *statusCode = parsedStatus;
    if (contentLength) *contentLength = parsedLength;
    if (initialBody) *initialBody = body;
    return fd;
}

static NSData *VCMFetchSmallResponse(NSString *path) {
    NSInteger status = 0;
    unsigned long long expectedLength = ULLONG_MAX;
    NSMutableData *body = nil;
    int fd = VCMOpenLocalRequest(path, &status, &expectedLength, &body);
    if (fd < 0) return nil;

    if (status != 200 || expectedLength == ULLONG_MAX || expectedLength > 128 * 1024) {
        close(fd);
        return nil;
    }

    while (body.length < expectedLength) {
        uint8_t buffer[4096];
        size_t remaining = (size_t)(expectedLength - body.length);
        ssize_t amount = recv(fd, buffer, MIN(sizeof(buffer), remaining), 0);
        if (amount < 0) {
            if (errno == EINTR) continue;
            close(fd);
            return nil;
        }
        if (amount == 0) break;
        [body appendBytes:buffer length:(NSUInteger)amount];
    }
    close(fd);
    return body.length == expectedLength ? body : nil;
}

static BOOL VCMDownloadMedia(NSString *destinationPath) {
    NSInteger status = 0;
    unsigned long long expectedLength = ULLONG_MAX;
    NSMutableData *initialBody = nil;
    int socketFD = VCMOpenLocalRequest(@"/media", &status, &expectedLength, &initialBody);
    if (socketFD < 0) return NO;

    if (status != 200 || expectedLength == ULLONG_MAX ||
        expectedLength == 0 || expectedLength > 1024ULL * 1024ULL * 1024ULL) {
        close(socketFD);
        return NO;
    }

    int outputFD = open(destinationPath.fileSystemRepresentation,
                        O_WRONLY | O_CREAT | O_TRUNC,
                        0600);
    if (outputFD < 0) {
        close(socketFD);
        return NO;
    }

    BOOL success = initialBody.length <= expectedLength &&
        VCMWriteAll(outputFD, initialBody.bytes, initialBody.length);
    unsigned long long written = initialBody.length;
    while (success && written < expectedLength) {
        uint8_t buffer[64 * 1024];
        size_t remaining = (size_t)MIN((unsigned long long)sizeof(buffer),
                                        expectedLength - written);
        ssize_t amount = recv(socketFD, buffer, remaining, 0);
        if (amount < 0) {
            if (errno == EINTR) continue;
            success = NO;
            break;
        }
        if (amount == 0) {
            success = NO;
            break;
        }
        success = VCMWriteAll(outputFD, buffer, (size_t)amount);
        written += (unsigned long long)amount;
    }

    if (fsync(outputFD) != 0) success = NO;
    close(outputFD);
    close(socketFD);

    if (!success || written != expectedLength) {
        unlink(destinationPath.fileSystemRepresentation);
        return NO;
    }
    chmod(destinationPath.fileSystemRepresentation, 0644);
    return YES;
}

@interface VCMVideoFrame : NSObject
@property (nonatomic, assign) CVPixelBufferRef pixelBuffer;
@end

@implementation VCMVideoFrame
- (instancetype)initWithPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    self = [super init];
    if (self && pixelBuffer) _pixelBuffer = CVPixelBufferRetain(pixelBuffer);
    return self;
}
- (void)dealloc {
    if (_pixelBuffer) CVPixelBufferRelease(_pixelBuffer);
}
@end

@interface VCamMediaServerSource () {
    dispatch_queue_t _monitorQueue;
    dispatch_queue_t _decodeQueue;
    dispatch_source_t _monitorTimer;
    NSRecursiveLock *_lock;

    BOOL _enabled;
    BOOL _loading;
    NSInteger _loadedRevision;
    NSInteger _loadingRevision;
    NSInteger _failedRevision;
    CFTimeInterval _lastLoadAttempt;

    CGFloat _zoom;
    CGFloat _offsetX;
    CGFloat _offsetY;

    NSString *_mediaType;
    NSString *_mediaPath;
    CIImage *_stillImage;
    AVURLAsset *_asset;
    AVAssetTrack *_videoTrack;
    AVAssetReader *_reader;
    AVAssetReaderTrackOutput *_readerOutput;
    NSMutableArray<VCMVideoFrame *> *_videoFrames;
    VCMVideoFrame *_lastVideoFrame;
    BOOL _prefetchScheduled;

    CIContext *_ciContext;
    CGColorSpaceRef _colorSpace;
}
- (void)refreshRemoteState;
- (void)beginMediaLoadForRevision:(NSInteger)revision
                             type:(NSString *)type
                        extension:(NSString *)extension;
- (void)prefetchVideoFrames;
@end

@implementation VCamMediaServerSource

+ (instancetype)sharedSource {
    static VCamMediaServerSource *source = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        source = [[VCamMediaServerSource alloc] init];
    });
    return source;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _monitorQueue = dispatch_queue_create("com.vcam.pro.mediaserver.monitor",
                                              DISPATCH_QUEUE_SERIAL);
        _decodeQueue = dispatch_queue_create("com.vcam.pro.mediaserver.decode",
                                             DISPATCH_QUEUE_SERIAL);
        _lock = [[NSRecursiveLock alloc] init];
        _videoFrames = [NSMutableArray array];
        _loadedRevision = -1;
        _loadingRevision = -1;
        _failedRevision = -1;
        _zoom = 1.0;
        _ciContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
        _colorSpace = CGColorSpaceCreateDeviceRGB();
    }
    return self;
}

- (void)dealloc {
    if (_monitorTimer) dispatch_source_cancel(_monitorTimer);
    if (_colorSpace) CGColorSpaceRelease(_colorSpace);
    if (_reader.status == AVAssetReaderStatusReading) [_reader cancelReading];
}

- (void)startMonitoring {
    dispatch_async(_monitorQueue, ^{
        if (self->_monitorTimer) return;
        [self refreshRemoteState];

        self->_monitorTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,
                                                     0,
                                                     0,
                                                     self->_monitorQueue);
        dispatch_source_set_timer(self->_monitorTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, 0),
                                  (uint64_t)(NSEC_PER_SEC / 2),
                                  (uint64_t)(NSEC_PER_MSEC * 40));
        dispatch_source_set_event_handler(self->_monitorTimer, ^{
            [self refreshRemoteState];
        });
        dispatch_resume(self->_monitorTimer);
    });
}

- (void)refreshRemoteState {
    NSData *data = VCMFetchSmallResponse(@"/state");
    if (!data) return;

    NSError *error = nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![object isKindOfClass:[NSDictionary class]]) {
        NSLog(@"[VCam Pro/MediaServer] Estado IPC inválido: %@", error);
        return;
    }

    NSDictionary *state = (NSDictionary *)object;
    BOOL enabled = [state[@"enabled"] boolValue];
    BOOL hasMedia = [state[@"mediaAvailable"] boolValue];
    NSInteger revision = [state[@"mediaRevision"] integerValue];
    NSString *type = [state[@"mediaType"] isKindOfClass:[NSString class]]
        ? state[@"mediaType"] : @"";
    NSString *extension = [state[@"mediaExtension"] isKindOfClass:[NSString class]]
        ? state[@"mediaExtension"] : @"mp4";

    [_lock lock];
    _enabled = enabled;
    _zoom = MAX(0.5, MIN(4.0, [state[@"zoom"] doubleValue]));
    _offsetX = MAX(-1.0, MIN(1.0, [state[@"offsetX"] doubleValue]));
    _offsetY = MAX(-1.0, MIN(1.0, [state[@"offsetY"] doubleValue]));

    BOOL needsLoad = enabled && hasMedia && revision > 0 &&
        revision != _loadedRevision && revision != _loadingRevision &&
        (revision != _failedRevision || CACurrentMediaTime() - _lastLoadAttempt > 5.0);
    if (needsLoad) {
        _loading = YES;
        _loadingRevision = revision;
        _lastLoadAttempt = CACurrentMediaTime();
    }
    [_lock unlock];

    if (needsLoad) {
        [self beginMediaLoadForRevision:revision type:type extension:extension];
    }
}

- (void)beginMediaLoadForRevision:(NSInteger)revision
                             type:(NSString *)type
                        extension:(NSString *)extension {
    dispatch_async(_decodeQueue, ^{
        NSString *safeExtension = extension.lowercaseString;
        NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
                                   @"abcdefghijklmnopqrstuvwxyz0123456789"];
        safeExtension = [[safeExtension componentsSeparatedByCharactersInSet:allowed.invertedSet]
                         componentsJoinedByString:@""];
        if (safeExtension.length == 0 || safeExtension.length > 8) safeExtension = @"mp4";

        NSString *filename = [NSString stringWithFormat:@"vcam_ms_%ld.%@",
                              (long)revision, safeExtension];
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:filename];

        if (!VCMDownloadMedia(path)) {
            [self->_lock lock];
            self->_loading = NO;
            self->_loadingRevision = -1;
            self->_failedRevision = revision;
            [self->_lock unlock];
            NSLog(@"[VCam Pro/MediaServer] No se pudo descargar el medio desde SpringBoard.");
            return;
        }

        BOOL success = NO;
        if ([type isEqualToString:@"image"]) {
            NSURL *url = [NSURL fileURLWithPath:path];
            CGImageSourceRef imageSource = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
            CGImageRef image = imageSource ? CGImageSourceCreateImageAtIndex(imageSource, 0, NULL) : NULL;
            if (imageSource) CFRelease(imageSource);

            if (image) {
                CIImage *still = [CIImage imageWithCGImage:image];
                CGImageRelease(image);
                [self->_lock lock];
                self->_stillImage = still;
                self->_asset = nil;
                self->_videoTrack = nil;
                self->_reader = nil;
                self->_readerOutput = nil;
                [self->_videoFrames removeAllObjects];
                self->_lastVideoFrame = nil;
                self->_mediaType = @"image";
                self->_mediaPath = path;
                self->_loadedRevision = revision;
                self->_failedRevision = -1;
                self->_loading = NO;
                self->_loadingRevision = -1;
                [self->_lock unlock];
                success = YES;
            }
        } else {
            NSURL *url = [NSURL fileURLWithPath:path];
            AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
            NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
            AVAssetTrack *track = tracks.firstObject;
            if (track) {
                NSError *readerError = nil;
                AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&readerError];
                NSDictionary *settings = @{
                    (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                    (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
                };
                AVAssetReaderTrackOutput *output =
                    [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:settings];

                if (reader && [reader canAddOutput:output]) {
                    output.alwaysCopiesSampleData = NO;
                    [reader addOutput:output];
                    if ([reader startReading]) {
                        [self->_lock lock];
                        if (self->_reader.status == AVAssetReaderStatusReading) {
                            [self->_reader cancelReading];
                        }
                        self->_stillImage = nil;
                        self->_asset = asset;
                        self->_videoTrack = track;
                        self->_reader = reader;
                        self->_readerOutput = output;
                        [self->_videoFrames removeAllObjects];
                        self->_lastVideoFrame = nil;
                        self->_mediaType = @"video";
                        self->_mediaPath = path;
                        self->_loadedRevision = revision;
                        self->_failedRevision = -1;
                        self->_loading = NO;
                        self->_loadingRevision = -1;
                        [self->_lock unlock];
                        success = YES;
                    }
                }
                if (!success) NSLog(@"[VCam Pro/MediaServer] No se pudo iniciar AVAssetReader: %@", readerError);
            }
        }

        if (!success) {
            [self->_lock lock];
            self->_loading = NO;
            self->_loadingRevision = -1;
            self->_failedRevision = revision;
            [self->_lock unlock];
            NSLog(@"[VCam Pro/MediaServer] No se pudo preparar el medio %@.", path.lastPathComponent);
        } else {
            NSLog(@"[VCam Pro/MediaServer] Medio listo: %@ (rev %ld).",
                  path.lastPathComponent, (long)revision);
            [self prefetchVideoFrames];
        }
    });
}

- (void)prefetchVideoFrames {
    if (_prefetchScheduled) return;
    _prefetchScheduled = YES;

    dispatch_async(_decodeQueue, ^{
        @autoreleasepool {
            NSUInteger attempts = 0;
            while (attempts < 12) {
                [self->_lock lock];
                BOOL videoMode = [self->_mediaType isEqualToString:@"video"];
                NSUInteger queued = self->_videoFrames.count;
                [self->_lock unlock];

                if (!videoMode || queued >= 4) break;

                CMSampleBufferRef sample = [self->_readerOutput copyNextSampleBuffer];
                if (!sample) {
                    if (self->_reader.status == AVAssetReaderStatusCompleted) {
                        NSError *restartError = nil;
                        AVAssetReader *reader =
                            [[AVAssetReader alloc] initWithAsset:self->_asset error:&restartError];
                        NSDictionary *settings = @{
                            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                            (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
                        };
                        AVAssetReaderTrackOutput *output =
                            [[AVAssetReaderTrackOutput alloc] initWithTrack:self->_videoTrack
                                                             outputSettings:settings];
                        if (reader && [reader canAddOutput:output]) {
                            output.alwaysCopiesSampleData = NO;
                            [reader addOutput:output];
                            if ([reader startReading]) {
                                self->_reader = reader;
                                self->_readerOutput = output;
                                attempts++;
                                continue;
                            }
                        }
                    }
                    break;
                }

                CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sample);
                if (pixelBuffer) {
                    VCMVideoFrame *frame = [[VCMVideoFrame alloc] initWithPixelBuffer:pixelBuffer];
                    [self->_lock lock];
                    [self->_videoFrames addObject:frame];
                    [self->_lock unlock];
                }
                CFRelease(sample);
                attempts++;
            }
            self->_prefetchScheduled = NO;
        }
    });
}

- (BOOL)renderNextFrameIntoPixelBuffer:(CVPixelBufferRef)targetBuffer {
    if (!targetBuffer) return NO;

    OSType pixelFormat = CVPixelBufferGetPixelFormatType(targetBuffer);
    BOOL supportedFormat =
        pixelFormat == kCVPixelFormatType_32BGRA ||
        pixelFormat == kCVPixelFormatType_32ARGB ||
        pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
        pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    if (!supportedFormat) return NO;

    CIImage *sourceImage = nil;
    VCMVideoFrame *frameToRender = nil;

    [_lock lock];
    BOOL active = _enabled && !_loading;
    if (active && [_mediaType isEqualToString:@"image"]) {
        sourceImage = _stillImage;
    } else if (active && [_mediaType isEqualToString:@"video"]) {
        if (_videoFrames.count > 0) {
            frameToRender = _videoFrames.firstObject;
            [_videoFrames removeObjectAtIndex:0];
            _lastVideoFrame = frameToRender;
        } else {
            frameToRender = _lastVideoFrame;
        }
    }
    CGFloat zoom = _zoom;
    CGFloat offsetX = _offsetX;
    CGFloat offsetY = _offsetY;
    [_lock unlock];

    if (frameToRender.pixelBuffer) {
        sourceImage = [CIImage imageWithCVPixelBuffer:frameToRender.pixelBuffer];
    }
    if (!sourceImage) return NO;

    size_t width = CVPixelBufferGetWidth(targetBuffer);
    size_t height = CVPixelBufferGetHeight(targetBuffer);
    CGRect sourceExtent = sourceImage.extent;
    if (width == 0 || height == 0 ||
        CGRectIsEmpty(sourceExtent) || sourceExtent.size.width <= 0 || sourceExtent.size.height <= 0) {
        return NO;
    }

    CGFloat scale = MAX((CGFloat)width / sourceExtent.size.width,
                        (CGFloat)height / sourceExtent.size.height) * zoom;
    CIImage *scaled = [sourceImage imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    CGRect scaledExtent = scaled.extent;
    CGFloat translateX = ((CGFloat)width - scaledExtent.size.width) * 0.5 + offsetX * width;
    CGFloat translateY = ((CGFloat)height - scaledExtent.size.height) * 0.5 + offsetY * height;
    CIImage *positioned = [scaled imageByApplyingTransform:
        CGAffineTransformMakeTranslation(translateX - scaledExtent.origin.x,
                                         translateY - scaledExtent.origin.y)];
    CGRect targetBounds = CGRectMake(0, 0, width, height);
    CIImage *cropped = [positioned imageByCroppingToRect:targetBounds];

    @try {
        [_ciContext render:cropped
           toCVPixelBuffer:targetBuffer
                    bounds:targetBounds
                colorSpace:_colorSpace];
    } @catch (NSException *exception) {
        NSLog(@"[VCam Pro/MediaServer] Error renderizando fotograma: %@", exception);
        return NO;
    }

    CVBufferSetAttachment(targetBuffer,
                          (__bridge CFStringRef)kVCamSystemReplacementAttachment,
                          kCFBooleanTrue,
                          kCVAttachmentMode_ShouldPropagate);

    if ([_mediaType isEqualToString:@"video"]) {
        [_lock lock];
        NSUInteger queued = _videoFrames.count;
        [_lock unlock];
        if (queued < 3) [self prefetchVideoFrames];
    }
    return YES;
}

@end
