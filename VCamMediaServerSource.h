#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT void VCMReportEngineStatus(NSString *status, NSString *detail);

@interface VCamMediaServerSource : NSObject
+ (instancetype)sharedSource;
- (void)startMonitoring;
- (BOOL)renderNextFrameIntoPixelBuffer:(CVPixelBufferRef)targetBuffer;
@end

NS_ASSUME_NONNULL_END
