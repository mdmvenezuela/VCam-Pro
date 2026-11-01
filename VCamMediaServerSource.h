#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT void VCMReportEngineStatus(NSString *status, NSString *detail);
FOUNDATION_EXPORT void VCMReportOrientationDiagnostic(NSString *line);

@interface VCamMediaServerSource : NSObject
+ (instancetype)sharedSource;
- (void)startMonitoring;
- (BOOL)isReplacementEnabled;
- (nullable CVPixelBufferRef)copyReplacementPixelBufferMatching:(CVPixelBufferRef)templateBuffer CF_RETURNS_RETAINED;
@end

NS_ASSUME_NONNULL_END
