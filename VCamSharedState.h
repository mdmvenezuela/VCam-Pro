#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface VCamSharedState : NSObject

@property (nonatomic, readonly, getter=isEnabled) BOOL enabled;
@property (nonatomic, copy, readonly, nullable) NSString *mediaType;
@property (nonatomic, copy, readonly, nullable) NSString *mediaExtension;
@property (nonatomic, copy, readonly, nullable) NSString *mediaPath;
@property (nonatomic, assign, readonly) NSInteger mediaRevision;
@property (nonatomic, assign, readonly) NSInteger stateRevision;
@property (nonatomic, assign, readonly) CGFloat zoom;
@property (nonatomic, assign, readonly) CGFloat offsetX;
@property (nonatomic, assign, readonly) CGFloat offsetY;
@property (nonatomic, assign, readonly) NSInteger rotationDegrees;
@property (nonatomic, assign, readonly) BOOL mirrorEnabled;
@property (nonatomic, assign, readonly) BOOL motionEnabled;
@property (nonatomic, assign, readonly) CGFloat buttonX;
@property (nonatomic, assign, readonly) CGFloat buttonY;

+ (instancetype)sharedState;

/// Starts the localhost IPC server. Call this only from SpringBoard.
- (BOOL)startServer;

/// Imports media into SpringBoard's private container and publishes it to app processes.
- (BOOL)importImage:(UIImage *)image error:(NSError * _Nullable * _Nullable)error;
- (BOOL)importVideoAtURL:(NSURL *)url error:(NSError * _Nullable * _Nullable)error;

- (void)setEnabled:(BOOL)enabled;
- (void)setMirrorEnabled:(BOOL)enabled;
- (void)setMotionEnabled:(BOOL)enabled;
- (void)setTransformWithZoom:(CGFloat)zoom
                    offsetX:(CGFloat)offsetX
                    offsetY:(CGFloat)offsetY
            rotationDegrees:(NSInteger)rotationDegrees;
- (void)adjustOffsetX:(CGFloat)deltaX offsetY:(CGFloat)deltaY;
- (void)adjustZoomBy:(CGFloat)delta;
- (void)resetImageTransform;
- (void)setButtonNormalizedX:(CGFloat)x y:(CGFloat)y;

@end

NS_ASSUME_NONNULL_END
