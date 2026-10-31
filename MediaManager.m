
#import "MediaManager.h"

#import <AudioToolbox/AudioToolbox.h>
#import <QuartzCore/QuartzCore.h>
#import <string.h>

#pragma mark - Private Interface

@interface MediaManager ()

@property (nonatomic, strong) dispatch_queue_t decodeQueue;
@property (nonatomic, strong) NSRecursiveLock *stateLock;

@property (nonatomic, assign) CMTime startTime;
@property (nonatomic, assign) int64_t frameIndex;

- (void)resetVideoReaderLocked;
- (void)resetAudioReaderLocked;
- (CMSampleBufferRef)createBlackFrameLocked;

@end

#pragma mark - Implementation

@implementation MediaManager

#pragma mark Singleton

+ (instancetype)sharedManager {

    static MediaManager *instance = nil;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{

        instance = [[MediaManager alloc] init];
    });

    return instance;
}

#pragma mark Initialization

- (instancetype)init {

    self = [super init];

    if (self) {

        _mode = VCamModeBlack;

        _loopPlayback = YES;
        _isRunning = NO;

        _videoSize = CGSizeMake(1280, 720);
        _videoDuration = kCMTimeZero;

        _startTime = kCMTimeZero;
        _frameIndex = 0;

        _decodeQueue = dispatch_queue_create(
            "com.vcam.pro.decode",
            DISPATCH_QUEUE_SERIAL
        );

        _stateLock = [[NSRecursiveLock alloc] init];
    }

    return self;
}

#pragma mark - Media Loading

- (void)loadMediaFromURL:(NSURL *)url {

    if (!url) {

        NSLog(@"[VCam Pro] URL de vídeo inválida");

        return;
    }

    dispatch_async(self.decodeQueue, ^{

        @autoreleasepool {

            AVURLAsset *asset = [AVURLAsset assetWithURL:url];

            if (!asset) {

                NSLog(@"[VCam Pro] No se pudo crear AVAsset");

                return;
            }

            NSArray<AVAssetTrack *> *videoTracks =
                [asset tracksWithMediaType:AVMediaTypeVideo];

            if (videoTracks.count == 0) {

                NSLog(@"[VCam Pro] El archivo no contiene una pista de vídeo");

                return;
            }

            AVAssetTrack *track = videoTracks.firstObject;

            CGSize size = track.naturalSize;

            CGAffineTransform transform = track.preferredTransform;

            size = CGSizeApplyAffineTransform(size, transform);

            size.width = fabs(size.width);
            size.height = fabs(size.height);

            if (size.width <= 0 || size.height <= 0) {

                NSLog(@"[VCam Pro] Dimensiones de vídeo inválidas");

                return;
            }

            [self.stateLock lock];

            @try {

                // Detener lectores anteriores.
                [self resetReaders];

                self.currentAsset = asset;

                self.videoDuration = asset.duration;

                self.videoSize = size;

                self.mode = VCamModeVideo;

                self.frameIndex = 0;

                // Crear lectores nuevos.
                [self resetReaders];

                NSLog(
                    @"[VCam Pro] Vídeo cargado: %.0fx%.0f",
                    size.width,
                    size.height
                );

            } @finally {

                [self.stateLock unlock];
            }
        }
    });
}

#pragma mark - Reader Management

- (void)resetReaders {

    [self.stateLock lock];

    @try {

        [self resetVideoReaderLocked];

        [self resetAudioReaderLocked];

    } @finally {

        [self.stateLock unlock];
    }
}

- (void)resetVideoReaderLocked {

    if (self.videoReader &&
        self.videoReader.status == AVAssetReaderStatusReading) {

        [self.videoReader cancelReading];
    }

    self.videoReader = nil;
    self.videoOutput = nil;

    if (!self.currentAsset) {
        return;
    }

    NSError *error = nil;

    AVAssetReader *reader = [
        [AVAssetReader alloc]
        initWithAsset:self.currentAsset
        error:&error
    ];

    if (!reader) {

        NSLog(
            @"[VCam Pro] Error creando lector de vídeo: %@",
            error
        );

        return;
    }

    NSArray<AVAssetTrack *> *tracks =
        [self.currentAsset tracksWithMediaType:AVMediaTypeVideo];

    if (tracks.count == 0) {
        return;
    }

    AVAssetTrack *track = tracks.firstObject;

    NSDictionary *settings = @{

        (NSString *)kCVPixelBufferPixelFormatTypeKey:
            @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),

        (NSString *)kCVPixelBufferIOSurfacePropertiesKey:
            @{}
    };

    AVAssetReaderTrackOutput *output = [
        [AVAssetReaderTrackOutput alloc]
        initWithTrack:track
        outputSettings:settings
    ];

    output.alwaysCopiesSampleData = NO;

    if (![reader canAddOutput:output]) {

        NSLog(@"[VCam Pro] No se pudo agregar la salida de vídeo");

        return;
    }

    [reader addOutput:output];

    if (![reader startReading]) {

        NSLog(
            @"[VCam Pro] Error iniciando lector de vídeo: %@",
            reader.error
        );

        return;
    }

    self.videoReader = reader;
    self.videoOutput = output;

    self.frameIndex = 0;
}

- (void)resetAudioReaderLocked {

    if (self.audioReader &&
        self.audioReader.status == AVAssetReaderStatusReading) {

        [self.audioReader cancelReading];
    }

    self.audioReader = nil;
    self.audioOutput = nil;

    if (!self.currentAsset) {
        return;
    }

    NSArray<AVAssetTrack *> *tracks =
        [self.currentAsset tracksWithMediaType:AVMediaTypeAudio];

    if (tracks.count == 0) {
        return;
    }

    NSError *error = nil;

    AVAssetReader *reader = [
        [AVAssetReader alloc]
        initWithAsset:self.currentAsset
        error:&error
    ];

    if (!reader) {

        NSLog(
            @"[VCam Pro] Error creando lector de audio: %@",
            error
        );

        return;
    }

    AVAssetTrack *track = tracks.firstObject;

    NSDictionary *settings = @{

        AVFormatIDKey: @(kAudioFormatLinearPCM),

        AVSampleRateKey: @(44100),

        AVNumberOfChannelsKey: @(2),

        AVLinearPCMBitDepthKey: @(16),

        AVLinearPCMIsFloatKey: @(NO),

        AVLinearPCMIsBigEndianKey: @(NO),

        AVLinearPCMIsNonInterleaved: @(NO)
    };

    AVAssetReaderTrackOutput *output = [
        [AVAssetReaderTrackOutput alloc]
        initWithTrack:track
        outputSettings:settings
    ];

    output.alwaysCopiesSampleData = NO;

    if (![reader canAddOutput:output]) {

        NSLog(@"[VCam Pro] No se pudo agregar la salida de audio");

        return;
    }

    [reader addOutput:output];

    if (![reader startReading]) {

        NSLog(
            @"[VCam Pro] Error iniciando lector de audio: %@",
            reader.error
        );

        return;
    }

    self.audioReader = reader;
    self.audioOutput = output;
}

#pragma mark - Video Frame

- (CMSampleBufferRef)nextVideoFrame {

    [self.stateLock lock];

    CMSampleBufferRef result = NULL;

    @try {

        if (!self.isRunning) {
            return NULL;
        }

        if (self.mode != VCamModeVideo || !self.videoOutput) {

            result = [self createBlackFrameLocked];

            return result;
        }

        CMSampleBufferRef sample =
            [self.videoOutput copyNextSampleBuffer];

        // Fin del vídeo: reiniciar reproducción.
        if (!sample && self.loopPlayback) {

            [self resetVideoReaderLocked];

            if (self.videoOutput) {

                sample = [self.videoOutput copyNextSampleBuffer];
            }
        }

        if (!sample) {

            result = [self createBlackFrameLocked];

            return result;
        }

        // Generar timestamp continuo.
        CMTime now = CMTimeMakeWithSeconds(
            CACurrentMediaTime(),
            1000000
        );

        CMSampleBufferRef copy = NULL;

        OSStatus status = CMSampleBufferCreateCopy(
            kCFAllocatorDefault,
            sample,
            &copy
        );

        CFRelease(sample);

        if (status != noErr || !copy) {

            NSLog(
                @"[VCam Pro] Error copiando frame: %d",
                (int)status
            );

            return NULL;
        }

        status = CMSampleBufferSetOutputPresentationTimeStamp(
            copy,
            now
        );

        if (status != noErr) {

            NSLog(
                @"[VCam Pro] Error actualizando timestamp: %d",
                (int)status
            );

            CFRelease(copy);

            return NULL;
        }

        self.frameIndex++;

        result = copy;

    } @finally {

        [self.stateLock unlock];
    }

    // El resultado es retenido para el llamador.
    return result;
}

#pragma mark - Audio Frame

- (CMSampleBufferRef)nextAudioFrame {

    [self.stateLock lock];

    CMSampleBufferRef result = NULL;

    @try {

        if (!self.isRunning || !self.audioOutput) {
            return NULL;
        }

        CMSampleBufferRef sample =
            [self.audioOutput copyNextSampleBuffer];

        // Reiniciar solamente el lector de audio.
        if (!sample && self.loopPlayback) {

            [self resetAudioReaderLocked];

            if (self.audioOutput) {

                sample = [self.audioOutput copyNextSampleBuffer];
            }
        }

        result = sample;

    } @finally {

        [self.stateLock unlock];
    }

    return result;
}

#pragma mark - Black Frame

- (CMSampleBufferRef)generateBlackFrameWithSize:(CGSize)size
                               presentationTime:(CMTime)pts {

    [self.stateLock lock];

    CMSampleBufferRef result = NULL;

    @try {

        CGFloat width = MAX(2.0, size.width);
        CGFloat height = MAX(2.0, size.height);

        // El formato YUV 4:2:0 requiere dimensiones pares.
        size_t pixelWidth = ((size_t)width) & ~((size_t)1);
        size_t pixelHeight = ((size_t)height) & ~((size_t)1);

        NSDictionary *attributes = @{

            (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},

            (NSString *)kCVPixelBufferMetalCompatibilityKey: @YES
        };

        CVPixelBufferRef pixelBuffer = NULL;

        CVReturn status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            pixelWidth,
            pixelHeight,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            (__bridge CFDictionaryRef)attributes,
            &pixelBuffer
        );

        if (status != kCVReturnSuccess || !pixelBuffer) {

            NSLog(
                @"[VCam Pro] Error creando pixel buffer: %d",
                status
            );

            return NULL;
        }

        status = CVPixelBufferLockBaseAddress(
            pixelBuffer,
            0
        );

        if (status != kCVReturnSuccess) {

            CVPixelBufferRelease(pixelBuffer);

            return NULL;
        }

        // Plano Y: luminancia negra en Full Range.
        void *yPlane = CVPixelBufferGetBaseAddressOfPlane(
            pixelBuffer,
            0
        );

        size_t yBytesPerRow =
            CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);

        size_t yHeight =
            CVPixelBufferGetHeightOfPlane(pixelBuffer, 0);

        memset(
            yPlane,
            0,
            yBytesPerRow * yHeight
        );

        // Plano UV: crominancia neutra.
        void *uvPlane = CVPixelBufferGetBaseAddressOfPlane(
            pixelBuffer,
            1
        );

        size_t uvBytesPerRow =
            CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);

        size_t uvHeight =
            CVPixelBufferGetHeightOfPlane(pixelBuffer, 1);

        memset(
            uvPlane,
            128,
            uvBytesPerRow * uvHeight
        );

        CVPixelBufferUnlockBaseAddress(
            pixelBuffer,
            0
        );

        CMVideoFormatDescriptionRef formatDescription = NULL;

        status = CMVideoFormatDescriptionCreateForImageBuffer(
            kCFAllocatorDefault,
            pixelBuffer,
            &formatDescription
        );

        if (status != noErr || !formatDescription) {

            CVPixelBufferRelease(pixelBuffer);

            return NULL;
        }

        CMSampleTimingInfo timing = {

            .duration = CMTimeMake(1, 30),

            .presentationTimeStamp = pts,

            .decodeTimeStamp = kCMTimeInvalid
        };

        CMSampleBufferRef sampleBuffer = NULL;

        status = CMSampleBufferCreateForImageBuffer(
            kCFAllocatorDefault,
            pixelBuffer,
            YES,
            NULL,
            NULL,
            formatDescription,
            &timing,
            &sampleBuffer
        );

        CFRelease(formatDescription);

        CVPixelBufferRelease(pixelBuffer);

        if (status != noErr || !sampleBuffer) {

            NSLog(
                @"[VCam Pro] Error creando sample buffer negro: %d",
                (int)status
            );

            return NULL;
        }

        result = sampleBuffer;

    } @finally {

        [self.stateLock unlock];
    }

    return result;
}

- (CMSampleBufferRef)createBlackFrameLocked {

    CMTime pts = CMTimeMakeWithSeconds(
        CACurrentMediaTime(),
        1000000
    );

    return [self generateBlackFrameWithSize:self.videoSize
                          presentationTime:pts];
}

#pragma mark - Lifecycle

- (void)start {

    [self.stateLock lock];

    @try {

        self.isRunning = YES;

        self.startTime = CMTimeMakeWithSeconds(
            CACurrentMediaTime(),
            1000000
        );

        if (self.currentAsset &&
            (!self.videoReader ||
             self.videoReader.status != AVAssetReaderStatusReading)) {

            [self resetReaders];
        }

        NSLog(@"[VCam Pro] MediaManager iniciado");

    } @finally {

        [self.stateLock unlock];
    }
}

- (void)stop {

    [self.stateLock lock];

    @try {

        self.isRunning = NO;

        if (self.videoReader &&
            self.videoReader.status == AVAssetReaderStatusReading) {

            [self.videoReader cancelReading];
        }

        if (self.audioReader &&
            self.audioReader.status == AVAssetReaderStatusReading) {

            [self.audioReader cancelReading];
        }

        self.videoReader = nil;
        self.videoOutput = nil;

        self.audioReader = nil;
        self.audioOutput = nil;

        self.frameIndex = 0;

        NSLog(@"[VCam Pro] MediaManager detenido");

    } @finally {

        [self.stateLock unlock];
    }
}

@end
