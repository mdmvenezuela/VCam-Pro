#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VCamMediaMode) {
    VCamMediaModeNone = 0,
    VCamMediaModePhoto = 1,
    VCamMediaModeVideo = 2
};

@interface MediaManager : NSObject

@property (nonatomic, assign, readonly) VCamMediaMode mode;
@property (nonatomic, assign, readonly, getter=isReady) BOOL ready;
@property (nonatomic, assign, readonly, getter=isRunning) BOOL running;
@property (nonatomic, assign) BOOL loopPlayback;

+ (instancetype)sharedManager;

- (void)loadMediaFromURL:(NSURL *)url
               mediaType:(NSString *)mediaType
              completion:(void (^)(BOOL success, NSError * _Nullable error))completion;

- (void)setZoom:(CGFloat)zoom offsetX:(CGFloat)offsetX offsetY:(CGFloat)offsetY;
- (void)setRotationDegrees:(NSInteger)rotationDegrees;
- (void)setMirrorEnabled:(BOOL)enabled;
- (void)setMotionEnabled:(BOOL)enabled;
- (void)start;
- (void)stop;

/// Returns a retained sample buffer in the requested dimensions/pixel format.
- (nullable CMSampleBufferRef)nextVideoFrameForSize:(CGSize)size
                                         pixelFormat:(OSType)pixelFormat CF_RETURNS_RETAINED;

/// Returns JPEG data for a still-photo capture path.
- (nullable NSData *)nextPhotoData;

@end

NS_ASSUME_NONNULL_END
