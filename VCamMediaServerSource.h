#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

@interface VCamMediaServerSource : NSObject
+ (instancetype)sharedSource;
- (void)startMonitoring;
- (BOOL)renderNextFrameIntoPixelBuffer:(CVPixelBufferRef)targetBuffer;
@end

NS_ASSUME_NONNULL_END
