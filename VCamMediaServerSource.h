#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT void VCMReportEngineStatus(NSString *status, NSString *detail);

@interface VCamMediaServerSource : NSObject
+ (instancetype)sharedSource;
- (void)startMonitoring;
- (nullable CVPixelBufferRef)copyReplacementPixelBufferMatching:(CVPixelBufferRef)templateBuffer CF_RETURNS_RETAINED;
@end

NS_ASSUME_NONNULL_END
