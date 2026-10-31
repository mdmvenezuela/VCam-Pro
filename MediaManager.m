#import "MediaManager.h"

#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>

@interface MediaManager () {
    NSRecursiveLock *_lock;
    dispatch_queue_t _decodeQueue;
    CIContext *_ciContext;

    VCamMediaMode _mode;
    BOOL _ready;
    BOOL _running;
    BOOL _loopPlayback;

    CIImage *_stillImage;
    AVURLAsset *_asset;
    AVAssetTrack *_videoTrack;
    AVAssetReader *_reader;
    AVAssetReaderTrackOutput *_readerOutput;
    CMSampleBufferRef _pendingVideoSample;
    CIImage *_lastVideoImage;
    CMTime _firstVideoPTS;
    CFTimeInterval _videoPlaybackStartTime;
    BOOL _hasVideoTiming;
    CGAffineTransform _preferredTransform;

    CGFloat _zoom;
    CGFloat _offsetX;
    CGFloat _offsetY;
}

- (BOOL)createReaderLocked:(NSError **)error;
- (void)destroyReaderLocked;
- (nullable CIImage *)nextSourceImageLocked;
- (CIImage *)transformedImageLocked:(CIImage *)image targetSize:(CGSize)size;

@end

@implementation MediaManager

+ (instancetype)sharedManager {
    static MediaManager *manager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[MediaManager alloc] init];
    });
    return manager;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = [[NSRecursiveLock alloc] init];
        _decodeQueue = dispatch_queue_create("com.vcam.pro.media.decode", DISPATCH_QUEUE_SERIAL);
        _ciContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
        _mode = VCamMediaModeNone;
        _ready = NO;
        _running = NO;
        _loopPlayback = YES;
        _zoom = 1.0;
        _offsetX = 0.0;
        _offsetY = 0.0;
        _preferredTransform = CGAffineTransformIdentity;
        _pendingVideoSample = NULL;
        _lastVideoImage = nil;
        _firstVideoPTS = kCMTimeInvalid;
        _videoPlaybackStartTime = 0.0;
        _hasVideoTiming = NO;
    }
    return self;
}

- (VCamMediaMode)mode {
    [_lock lock];
    VCamMediaMode value = _mode;
    [_lock unlock];
    return value;
}

- (BOOL)isReady {
    [_lock lock];
    BOOL value = _ready;
    [_lock unlock];
    return value;
}

- (BOOL)isRunning {
    [_lock lock];
    BOOL value = _running;
    [_lock unlock];
    return value;
}

- (void)loadMediaFromURL:(NSURL *)url
               mediaType:(NSString *)mediaType
              completion:(void (^)(BOOL, NSError * _Nullable))completion {

    if (!url.isFileURL || !url.path.length) {
        NSError *error = [NSError errorWithDomain:@"VCamPro.MediaManager"
                                             code:1
                                         userInfo:@{NSLocalizedDescriptionKey: @"La ruta del archivo multimedia no es válida."}];
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, error); });
        return;
    }

    dispatch_async(_decodeQueue, ^{
        @autoreleasepool {
            NSError *loadError = nil;
            BOOL success = NO;

            [self->_lock lock];
            [self destroyReaderLocked];
            self->_stillImage = nil;
            self->_asset = nil;
            self->_videoTrack = nil;
            self->_mode = VCamMediaModeNone;
            self->_ready = NO;
            self->_running = NO;
            self->_preferredTransform = CGAffineTransformIdentity;
            [self->_lock unlock];

            if ([mediaType isEqualToString:@"image"]) {
                UIImage *loadedImage = [UIImage imageWithContentsOfFile:url.path];
                if (loadedImage.CGImage) {
                    UIGraphicsBeginImageContextWithOptions(loadedImage.size, NO, 1.0);
                    [loadedImage drawInRect:(CGRect){CGPointZero, loadedImage.size}];
                    UIImage *normalizedImage = UIGraphicsGetImageFromCurrentImageContext();
                    UIGraphicsEndImageContext();

                    if (normalizedImage.CGImage) {
                        CIImage *ciImage = [CIImage imageWithCGImage:normalizedImage.CGImage];
                        [self->_lock lock];
                        self->_stillImage = ciImage;
                        self->_mode = VCamMediaModePhoto;
                        self->_ready = YES;
                        self->_running = YES;
                        [self->_lock unlock];
                        success = YES;
                    }
                }

                if (!success) {
                    loadError = [NSError errorWithDomain:@"VCamPro.MediaManager"
                                                     code:2
                                                 userInfo:@{NSLocalizedDescriptionKey: @"No se pudo abrir la imagen seleccionada."}];
                }
            } else {
                AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
                NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
                AVAssetTrack *track = tracks.firstObject;

                if (!track) {
                    loadError = [NSError errorWithDomain:@"VCamPro.MediaManager"
                                                     code:3
                                                 userInfo:@{NSLocalizedDescriptionKey: @"El archivo no contiene una pista de vídeo."}];
                } else {
                    [self->_lock lock];
                    self->_asset = asset;
                    self->_videoTrack = track;
                    self->_preferredTransform = track.preferredTransform;
                    success = [self createReaderLocked:&loadError];
                    self->_ready = success;
                    self->_mode = success ? VCamMediaModeVideo : VCamMediaModeNone;
                    self->_running = success;
                    [self->_lock unlock];
                }
            }

            NSLog(@"[VCam Pro] Carga multimedia %@: %@", success ? @"correcta" : @"fallida", url.lastPathComponent);
            if (!success && loadError) NSLog(@"[VCam Pro] Detalle de carga: %@", loadError);

            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(success, loadError);
                });
            }
        }
    });
}

- (BOOL)createReaderLocked:(NSError **)error {
    [self destroyReaderLocked];
    if (!_asset || !_videoTrack) return NO;

    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:_asset error:error];
    if (!reader) return NO;

    NSDictionary *settings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };

    AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc] initWithTrack:_videoTrack
                                                                        outputSettings:settings];
    output.alwaysCopiesSampleData = NO;

    if (![reader canAddOutput:output]) {
        if (error) *error = [NSError errorWithDomain:@"VCamPro.MediaManager"
                                                code:4
                                            userInfo:@{NSLocalizedDescriptionKey: @"AVAssetReader no acepta la salida de vídeo."}];
        return NO;
    }

    [reader addOutput:output];
    if (![reader startReading]) {
        if (error) *error = reader.error ?: [NSError errorWithDomain:@"VCamPro.MediaManager"
                                                                 code:5
                                                             userInfo:@{NSLocalizedDescriptionKey: @"No se pudo iniciar la lectura del vídeo."}];
        return NO;
    }

    _reader = reader;
    _readerOutput = output;
    return YES;
}

- (void)destroyReaderLocked {
    if (_reader && _reader.status == AVAssetReaderStatusReading) {
        [_reader cancelReading];
    }
    _reader = nil;
    _readerOutput = nil;

    if (_pendingVideoSample) {
        CFRelease(_pendingVideoSample);
        _pendingVideoSample = NULL;
    }
    _lastVideoImage = nil;
    _firstVideoPTS = kCMTimeInvalid;
    _videoPlaybackStartTime = 0.0;
    _hasVideoTiming = NO;
}

- (void)setZoom:(CGFloat)zoom offsetX:(CGFloat)offsetX offsetY:(CGFloat)offsetY {
    [_lock lock];
    _zoom = MAX(0.5, MIN(4.0, zoom));
    _offsetX = MAX(-1.0, MIN(1.0, offsetX));
    _offsetY = MAX(-1.0, MIN(1.0, offsetY));
    [_lock unlock];
}

- (void)start {
    [_lock lock];
    if (_ready) {
        _running = YES;
        if (_mode == VCamMediaModeVideo && (!_reader || _reader.status != AVAssetReaderStatusReading)) {
            NSError *error = nil;
            if (![self createReaderLocked:&error]) {
                _running = NO;
                NSLog(@"[VCam Pro] No se pudo reiniciar el vídeo: %@", error);
            }
        }
    }
    [_lock unlock];
}

- (void)stop {
    [_lock lock];
    _running = NO;
    if (_mode == VCamMediaModeVideo) [self destroyReaderLocked];
    [_lock unlock];
}

- (CIImage *)nextSourceImageLocked {
    if (!_ready || !_running) return nil;

    if (_mode == VCamMediaModePhoto) return _stillImage;
    if (_mode != VCamMediaModeVideo || !_readerOutput) return nil;

    // Consume all source frames that are due for the current host-clock time,
    // keeping the newest one. This naturally drops frames when the source is
    // faster than the camera output and repeats frames when it is slower.
    CFTimeInterval now = CACurrentMediaTime();
    NSUInteger consumedFrames = 0;
    BOOL restartedForLoop = NO;
    const NSUInteger maximumFramesPerCallback = 120;

    while (consumedFrames < maximumFramesPerCallback) {
        if (!_pendingVideoSample) {
            _pendingVideoSample = [_readerOutput copyNextSampleBuffer];
        }

        if (!_pendingVideoSample && _loopPlayback && !restartedForLoop) {
            restartedForLoop = YES;
            NSError *error = nil;
            if ([self createReaderLocked:&error]) {
                _pendingVideoSample = [_readerOutput copyNextSampleBuffer];
                now = CACurrentMediaTime();
            } else if (error) {
                NSLog(@"[VCam Pro] Error reiniciando el vídeo: %@", error);
            }
        }

        if (!_pendingVideoSample) break;

        CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(_pendingVideoSample);
        if (!_hasVideoTiming && CMTIME_IS_VALID(presentationTime)) {
            _firstVideoPTS = presentationTime;
            _videoPlaybackStartTime = now;
            _hasVideoTiming = YES;
        } else if (_hasVideoTiming && CMTIME_IS_VALID(presentationTime) && CMTIME_IS_VALID(_firstVideoPTS)) {
            double mediaElapsed = CMTimeGetSeconds(CMTimeSubtract(presentationTime, _firstVideoPTS));
            double wallElapsed = now - _videoPlaybackStartTime;
            if (isfinite(mediaElapsed) && isfinite(wallElapsed) &&
                mediaElapsed > wallElapsed + 0.004 && _lastVideoImage) {
                break;
            }
        }

        CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(_pendingVideoSample);
        CIImage *image = imageBuffer ? [CIImage imageWithCVPixelBuffer:imageBuffer] : nil;
        CFRelease(_pendingVideoSample);
        _pendingVideoSample = NULL;
        consumedFrames += 1;

        if (image) {
            if (!CGAffineTransformIsIdentity(_preferredTransform)) {
                image = [image imageByApplyingTransform:_preferredTransform];
            }

            CGRect extent = image.extent;
            if (!CGRectIsEmpty(extent) && (extent.origin.x != 0 || extent.origin.y != 0)) {
                image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(-extent.origin.x, -extent.origin.y)];
            }
            _lastVideoImage = image;
        }

        // Fetch the following frame now so its timestamp can be compared with
        // the playback clock on this callback.
        _pendingVideoSample = [_readerOutput copyNextSampleBuffer];
        now = CACurrentMediaTime();
    }

    return _lastVideoImage;
}

- (CIImage *)transformedImageLocked:(CIImage *)image targetSize:(CGSize)size {
    if (!image) return nil;

    CGFloat targetWidth = MAX(2.0, size.width);
    CGFloat targetHeight = MAX(2.0, size.height);
    CGRect extent = image.extent;
    if (CGRectIsEmpty(extent) || extent.size.width <= 0 || extent.size.height <= 0) return nil;

    if (extent.origin.x != 0 || extent.origin.y != 0) {
        image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(-extent.origin.x, -extent.origin.y)];
        extent = image.extent;
    }

    CGFloat fillScale = MAX(targetWidth / extent.size.width, targetHeight / extent.size.height);
    CGFloat scale = fillScale * _zoom;
    image = [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];

    CGRect scaledExtent = image.extent;
    CGFloat translateX = ((targetWidth - scaledExtent.size.width) * 0.5) + (_offsetX * targetWidth * 0.5);
    CGFloat translateY = ((targetHeight - scaledExtent.size.height) * 0.5) - (_offsetY * targetHeight * 0.5);
    image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(translateX - scaledExtent.origin.x,
                                                                            translateY - scaledExtent.origin.y)];

    CGRect targetRect = CGRectMake(0, 0, targetWidth, targetHeight);
    image = [image imageByCroppingToRect:targetRect];

    // Al permitir zoom por debajo de 1x, la imagen puede dejar márgenes.
    // Los rellenamos con negro opaco para entregar un fotograma completo.
    CIImage *background = [[CIImage imageWithColor:[CIColor colorWithRed:0 green:0 blue:0 alpha:1]]
                           imageByCroppingToRect:targetRect];
    return [image imageByCompositingOverImage:background];
}

- (CMSampleBufferRef)nextVideoFrameForSize:(CGSize)size pixelFormat:(OSType)pixelFormat {
    [_lock lock];

    CMSampleBufferRef result = NULL;
    CIImage *sourceImage = [self nextSourceImageLocked];
    if (!sourceImage) {
        [_lock unlock];
        return NULL;
    }

    if (size.width < 2 || size.height < 2) {
        CGRect extent = sourceImage.extent;
        size = extent.size;
    }

    if (pixelFormat != kCVPixelFormatType_32BGRA &&
        pixelFormat != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange &&
        pixelFormat != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
        pixelFormat = kCVPixelFormatType_32BGRA;
    }

    CIImage *outputImage = [self transformedImageLocked:sourceImage targetSize:size];
    if (!outputImage) {
        [_lock unlock];
        return NULL;
    }

    NSDictionary *attributes = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES
    };

    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn pixelStatus = CVPixelBufferCreate(kCFAllocatorDefault,
                                                (size_t)size.width,
                                                (size_t)size.height,
                                                pixelFormat,
                                                (__bridge CFDictionaryRef)attributes,
                                                &pixelBuffer);

    if (pixelStatus == kCVReturnSuccess && pixelBuffer) {
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        @try {
            [_ciContext render:outputImage
              toCVPixelBuffer:pixelBuffer
                        bounds:CGRectMake(0, 0, size.width, size.height)
                    colorSpace:colorSpace];
        } @catch (NSException *exception) {
            NSLog(@"[VCam Pro] Error renderizando fotograma: %@", exception);
            CVPixelBufferRelease(pixelBuffer);
            pixelBuffer = NULL;
        }
        if (colorSpace) CGColorSpaceRelease(colorSpace);
    }

    if (pixelBuffer) {
        CMVideoFormatDescriptionRef formatDescription = NULL;
        OSStatus formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault,
                                                                               pixelBuffer,
                                                                               &formatDescription);
        if (formatStatus == noErr && formatDescription) {
            CMTime pts = CMTimeMakeWithSeconds(CACurrentMediaTime(), 600);
            CMSampleTimingInfo timing = {
                .duration = CMTimeMake(1, 30),
                .presentationTimeStamp = pts,
                .decodeTimeStamp = kCMTimeInvalid
            };

            CMSampleBufferRef sampleBuffer = NULL;
            OSStatus sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault,
                                                                               pixelBuffer,
                                                                               formatDescription,
                                                                               &timing,
                                                                               &sampleBuffer);
            if (sampleStatus == noErr) result = sampleBuffer;
            if (formatDescription) CFRelease(formatDescription);
        }
        CVPixelBufferRelease(pixelBuffer);
    }

    [_lock unlock];
    return result;
}

- (NSData *)nextPhotoData {
    [_lock lock];
    CIImage *sourceImage = [self nextSourceImageLocked];
    if (!sourceImage) {
        [_lock unlock];
        return nil;
    }

    CGRect extent = sourceImage.extent;
    CGSize outputSize = extent.size;
    if (outputSize.width > 2400 || outputSize.height > 2400) {
        CGFloat factor = MIN(2400.0 / outputSize.width, 2400.0 / outputSize.height);
        outputSize = CGSizeMake(outputSize.width * factor, outputSize.height * factor);
    }

    CIImage *transformed = [self transformedImageLocked:sourceImage targetSize:outputSize];
    CGImageRef cgImage = transformed ? [_ciContext createCGImage:transformed fromRect:CGRectMake(0, 0, outputSize.width, outputSize.height)] : NULL;
    [_lock unlock];

    if (!cgImage) return nil;

    UIImage *image = [UIImage imageWithCGImage:cgImage scale:1.0 orientation:UIImageOrientationUp];
    CGImageRelease(cgImage);
    return UIImageJPEGRepresentation(image, 0.94);
}

@end
