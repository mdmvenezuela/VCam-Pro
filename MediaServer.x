#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <substrate.h>
#import <stdatomic.h>
#import <stdint.h>
#import <string.h>
#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <sys/time.h>
#import <unistd.h>
#import <errno.h>
#import <fcntl.h>
#import <sys/stat.h>

#import "VCamMediaServerSource.h"

typedef void (*VCMEmitSampleBufferFunction)(id object,
                                            SEL selector,
                                            CMSampleBufferRef sampleBuffer);

typedef struct {
    Class runtimeClass;
    SEL selector;
    VCMEmitSampleBufferFunction original;
} VCMNodeOutputHook;

static const NSUInteger kVCMMaximumHooks = 64;
static VCMNodeOutputHook g_vcmHooks[64];
static _Atomic(uint32_t) g_vcmHookCount = 0;
static _Atomic(uint32_t) g_vcmReplacementCount = 0;
static dispatch_queue_t g_vcmInstallQueue;
static _Atomic(uint32_t) g_vcmInstallQueued = 0;
static NSLock *g_vcmHookLock;
static dispatch_queue_t g_vcmStatusQueue;
static NSString *g_vcmLastReportedStatus;
static NSString *g_vcmLastReportedDetail;
static uint32_t g_vcmLastReportedFrames = 0;
static _Atomic(uint32_t) g_vcmUnreplacedCount = 0;
static const uint16_t kVCMStatusPort = 47831;

static _Atomic(uint32_t) g_vcmOrientationDiagnosticCount = 0;

static void VCMAppendOrientationDiagnostic(NSString *message) {
    if (![message isKindOfClass:[NSString class]] || message.length == 0) return;
    const char *directory = "/var/mobile/Documents";
    mkdir(directory, 0755);
    const char *path = "/var/mobile/Documents/VCam-OrientationDiag.log";
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) {
        NSLog(@"[VCam Pro/OrientationDiag] No se pudo abrir el archivo de diagnóstico: %s", strerror(errno));
        return;
    }
    NSString *line = [message stringByAppendingString:@"\n"];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *bytes = data.bytes;
    size_t remaining = data.length;
    while (remaining > 0) {
        ssize_t written = write(fd, bytes, remaining);
        if (written < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (written == 0) break;
        bytes += written;
        remaining -= (size_t)written;
    }
    close(fd);
}

static NSString *VCMDescribeDictionaryKeys(CFDictionaryRef dictionary) {
    if (!dictionary) return @"[]";
    CFIndex count = CFDictionaryGetCount(dictionary);
    if (count <= 0) return @"[]";
    const void **keys = calloc((size_t)count, sizeof(void *));
    if (!keys) return @"[allocation-failed]";
    CFDictionaryGetKeysAndValues(dictionary, keys, NULL);
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
    for (CFIndex index = 0; index < count; index++) {
        const void *key = keys[index];
        if (!key) continue;
        if (CFGetTypeID(key) == CFStringGetTypeID()) {
            [names addObject:(__bridge NSString *)key];
        } else {
            [names addObject:[NSString stringWithFormat:@"<%s>", CFGetTypeID(key) == CFNumberGetTypeID() ? "number" : "non-string"]];
        }
    }
    free(keys);
    [names sortUsingSelector:@selector(compare:)];
    return [NSString stringWithFormat:@"[%@]", [names componentsJoinedByString:@","]];
}

static void VCMLogCameraFrameContract(id object, CMSampleBufferRef sampleBuffer,
                                      CVPixelBufferRef pixelBuffer) {
    uint32_t index = atomic_fetch_add_explicit(&g_vcmOrientationDiagnosticCount, 1,
                                               memory_order_relaxed);
    if (index >= 24) return;

    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
    CMVideoDimensions formatDimensions = {0, 0};
    CFDictionaryRef formatExtensions = NULL;
    if (format && CMFormatDescriptionGetMediaType(format) == kCMMediaType_Video) {
        formatDimensions = CMVideoFormatDescriptionGetDimensions(
            (CMVideoFormatDescriptionRef)format);
        formatExtensions = CMFormatDescriptionGetExtensions(format);
    }

    CFDictionaryRef propagated = CVBufferGetAttachments(
        pixelBuffer, kCVAttachmentMode_ShouldPropagate);
    CFDictionaryRef nonPropagated = CVBufferGetAttachments(
        pixelBuffer, kCVAttachmentMode_ShouldNotPropagate);
    CFDictionaryRef sampleAttachments = CMCopyDictionaryOfAttachments(
        kCFAllocatorDefault, sampleBuffer, kCMAttachmentMode_ShouldPropagate);
    CFArrayRef perSample = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    CFDictionaryRef perSampleDictionary = perSample && CFArrayGetCount(perSample) > 0
        ? (CFDictionaryRef)CFArrayGetValueAtIndex(perSample, 0) : NULL;

    NSString *diagnostic = [NSString stringWithFormat:
        @"[VCam Pro/OrientationDiag] #%u node=%s pixel=%zux%zu format=%dx%d pixelFormat=%u formatExt=%@ pixelProp=%@ pixelNoProp=%@ sampleProp=%@ sampleEntry=%@",
        index + 1,
        object_getClassName(object),
        CVPixelBufferGetWidth(pixelBuffer),
        CVPixelBufferGetHeight(pixelBuffer),
        formatDimensions.width,
        formatDimensions.height,
        (unsigned int)CVPixelBufferGetPixelFormatType(pixelBuffer),
        VCMDescribeDictionaryKeys(formatExtensions),
        VCMDescribeDictionaryKeys(propagated),
        VCMDescribeDictionaryKeys(nonPropagated),
        VCMDescribeDictionaryKeys(sampleAttachments),
        VCMDescribeDictionaryKeys(perSampleDictionary)];
    NSLog(@"%@", diagnostic);
    VCMAppendOrientationDiagnostic(diagnostic);

    if (sampleAttachments) CFRelease(sampleAttachments);
}

static BOOL VCMSendStatusBytes(int fd, const void *bytes, size_t length) {
    const uint8_t *cursor = (const uint8_t *)bytes;
    size_t sent = 0;
    while (sent < length) {
        ssize_t amount = send(fd, cursor + sent, length - sent, 0);
        if (amount < 0) {
            if (errno == EINTR) continue;
            return NO;
        }
        if (amount == 0) return NO;
        sent += (size_t)amount;
    }
    return YES;
}

void VCMReportEngineStatus(NSString *status, NSString *detail) {
    if (!status.length || !g_vcmStatusQueue) return;

    NSString *safeStatus = [status copy];
    NSString *safeDetail = [detail isKindOfClass:[NSString class]] ? [detail copy] : @"";
    dispatch_async(g_vcmStatusQueue, ^{
        uint32_t hooks = atomic_load_explicit(&g_vcmHookCount, memory_order_acquire);
        uint32_t frames = atomic_load_explicit(&g_vcmReplacementCount, memory_order_relaxed);
        BOOL changed = ![g_vcmLastReportedStatus isEqualToString:safeStatus];
        BOOL detailChanged = ![g_vcmLastReportedDetail isEqualToString:safeDetail];
        BOOL progressed = frames >= g_vcmLastReportedFrames + 120;
        if (!changed && !detailChanged && !progressed) return;

        NSDictionary *payload = @{
            @"status": safeStatus,
            @"detail": safeDetail,
            @"hooks": @(hooks),
            @"frames": @(frames)
        };
        NSError *jsonError = nil;
        NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&jsonError];
        if (!body) return;

        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) return;
        int noSignal = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal));

        struct timeval timeout = {1, 0};
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

        struct sockaddr_in address;
        memset(&address, 0, sizeof(address));
        address.sin_len = sizeof(address);
        address.sin_family = AF_INET;
        address.sin_port = htons(kVCMStatusPort);
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

        if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
            close(fd);
            return;
        }

        NSString *header = [NSString stringWithFormat:
            @"POST /engine-status HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n",
            (unsigned long)body.length];
        BOOL sent = VCMSendStatusBytes(fd, header.UTF8String, header.length) &&
                    VCMSendStatusBytes(fd, body.bytes, body.length);
        close(fd);

        if (sent) {
            g_vcmLastReportedStatus = safeStatus;
            g_vcmLastReportedDetail = safeDetail;
            g_vcmLastReportedFrames = frames;
        }
    });
}
static CFStringRef const kVCMSystemReplacementAttachment =
    CFSTR("com.vcam.pro.systemreplacement.v1");

static Method VCMDirectInstanceMethod(Class runtimeClass, SEL selector) {
    if (!runtimeClass || !selector) return NULL;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(runtimeClass, &count);
    Method result = NULL;
    for (unsigned int index = 0; index < count; index++) {
        if (method_getName(methods[index]) == selector) {
            result = methods[index];
            break;
        }
    }
    free(methods);
    return result;
}

static BOOL VCMHasCompatibleSampleSignature(Method method) {
    if (!method || method_getNumberOfArguments(method) != 3) return NO;

    char returnType[32] = {0};
    char sampleType[96] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    method_getArgumentType(method, 2, sampleType, sizeof(sampleType));

    const char *argument = sampleType;
    while (*argument == 'r' || *argument == 'n' || *argument == 'N' ||
           *argument == 'o' || *argument == 'O' || *argument == 'R' ||
           *argument == 'V') argument++;

    return returnType[0] == 'v' && argument[0] == '^';
}

static BOOL VCMIsSubclassOfClass(Class candidate, Class baseClass) {
    if (!candidate || !baseClass || candidate == baseClass) return NO;
    for (Class current = class_getSuperclass(candidate); current;
         current = class_getSuperclass(current)) {
        if (current == baseClass) return YES;
    }
    return NO;
}

static VCMEmitSampleBufferFunction VCMOriginalForObject(id object, SEL selector) {
    if (!object) return NULL;
    Class runtimeClass = object_getClass(object);
    uint32_t count = atomic_load_explicit(&g_vcmHookCount, memory_order_acquire);

    for (Class current = runtimeClass; current; current = class_getSuperclass(current)) {
        for (uint32_t index = 0; index < count; index++) {
            VCMNodeOutputHook *entry = &g_vcmHooks[index];
            if (entry->runtimeClass == current && entry->selector == selector) {
                return entry->original;
            }
        }
    }
    return NULL;
}

static void VCMEmitSampleBuffer(id object,
                                SEL selector,
                                CMSampleBufferRef sampleBuffer) {
    @autoreleasepool {
        VCMEmitSampleBufferFunction original = VCMOriginalForObject(object, selector);
        if (!original) {
            NSLog(@"[VCam Pro/MediaServer] No se encontró IMP original para %@.",
                  NSStringFromClass(object_getClass(object)));
            return;
        }

        if (!sampleBuffer) {
            original(object, selector, sampleBuffer);
            return;
        }

        // Fast path: a fan-out node may receive the very same sample again.
        if (CMGetAttachment(sampleBuffer, kVCMSystemReplacementAttachment, NULL) ==
            kCFBooleanTrue) {
            original(object, selector, sampleBuffer);
            return;
        }

        CVImageBufferRef inputImageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (!inputImageBuffer) {
            original(object, selector, sampleBuffer);
            return;
        }

        SEL mediaTypeSelector = sel_registerName("mediaType");
        uint32_t mediaType = 0;
        if ([object respondsToSelector:mediaTypeSelector]) {
            mediaType = ((uint32_t (*)(id, SEL))objc_msgSend)(object, mediaTypeSelector);
        }
        if (mediaType != 'vide') {
            original(object, selector, sampleBuffer);
            return;
        }

        VCamMediaServerSource *source = [VCamMediaServerSource sharedSource];
        if (![source isReplacementEnabled]) {
            original(object, selector, sampleBuffer);
            return;
        }

        BOOL alreadyReplaced = NO;
        BOOL replacementSucceeded = NO;

        // Serialize only callers holding this exact CMSampleBuffer. Other
        // camera frames can continue rendering concurrently.
        @synchronized ((__bridge id)sampleBuffer) {
            alreadyReplaced =
                CMGetAttachment(sampleBuffer, kVCMSystemReplacementAttachment, NULL) ==
                kCFBooleanTrue;

            if (!alreadyReplaced) {
                VCMLogCameraFrameContract(object, sampleBuffer,
                                          (CVPixelBufferRef)inputImageBuffer);

                replacementSucceeded =
                    [source renderReplacementIntoPixelBuffer:(CVPixelBufferRef)inputImageBuffer];

                if (replacementSucceeded) {
                    // Mark the sample, not its reusable CVPixelBuffer. This
                    // prevents duplicate work without leaving a stale marker
                    // on a camera-pool buffer recycled for a later frame.
                    CMSetAttachment(sampleBuffer,
                                    kVCMSystemReplacementAttachment,
                                    kCFBooleanTrue,
                                    kCMAttachmentMode_ShouldPropagate);
                }
            }
        }

        if (!alreadyReplaced && !replacementSucceeded) {
            uint32_t attempts = atomic_fetch_add_explicit(&g_vcmUnreplacedCount,
                                                          1,
                                                          memory_order_relaxed) + 1;
            if (attempts == 1 || attempts % 300 == 0) {
                VCMReportEngineStatus(@"hook_active_no_frame",
                    @"El hook recibe fotogramas, pero no se pudieron renderizar los píxeles virtuales sobre el buffer original.");
            }
        }

        if (replacementSucceeded) {
            uint32_t count = atomic_fetch_add_explicit(&g_vcmReplacementCount,
                                                       1,
                                                       memory_order_relaxed) + 1;
            if (count <= 3 || count % 600 == 0) {
                NSLog(@"[VCam Pro/MediaServer] Fotograma sustituido in-place (#%u).", count);
            }
            if (count <= 3 || count % 120 == 0) {
                VCMReportEngineStatus(@"frames_replaced",
                    [NSString stringWithFormat:@"VCam sustituyó in-place %u fotogramas de cámara.", count]);
            }
        }

        // Keep the original CMSampleBuffer, format description, timing and all
        // camera/sample attachments. Only its pixel memory has been replaced.
        original(object, selector, sampleBuffer);
    }
}
static BOOL VCMInstallClassHook(Class candidate,
                                Class baseClass,
                                SEL selector) {
    if (!candidate || !baseClass) return NO;

    Method method = candidate == baseClass
        ? class_getInstanceMethod(candidate, selector)
        : VCMDirectInstanceMethod(candidate, selector);

    if (!method || !VCMHasCompatibleSampleSignature(method)) return NO;

    [g_vcmHookLock lock];
    uint32_t count = atomic_load_explicit(&g_vcmHookCount, memory_order_relaxed);
    for (uint32_t index = 0; index < count; index++) {
        if (g_vcmHooks[index].runtimeClass == candidate) {
            [g_vcmHookLock unlock];
            return NO;
        }
    }
    if (count >= kVCMMaximumHooks) {
        [g_vcmHookLock unlock];
        NSLog(@"[VCam Pro/MediaServer] Se alcanzó el límite de clases BWNodeOutput.");
        return NO;
    }

    IMP originalIMP = NULL;
    MSHookMessageEx(candidate, selector, (IMP)VCMEmitSampleBuffer, &originalIMP);
    if (!originalIMP) {
        [g_vcmHookLock unlock];
        NSLog(@"[VCam Pro/MediaServer] No se pudo instalar hook en %@.",
              NSStringFromClass(candidate));
        return NO;
    }

    g_vcmHooks[count].runtimeClass = candidate;
    g_vcmHooks[count].selector = selector;
    g_vcmHooks[count].original = (VCMEmitSampleBufferFunction)originalIMP;
    atomic_store_explicit(&g_vcmHookCount, count + 1, memory_order_release);
    [g_vcmHookLock unlock];

    NSLog(@"[VCam Pro/MediaServer] Hook instalado en %@.",
          NSStringFromClass(candidate));
    return YES;
}

static void VCMInstallMediaGraphHooks(void) {
    Class baseClass = objc_getClass("BWNodeOutput");
    if (!baseClass) {
        NSLog(@"[VCam Pro/MediaServer] BWNodeOutput todavía no está cargada.");
        VCMReportEngineStatus(@"waiting_for_class",
            @"mediaserverd está cargado, pero BWNodeOutput todavía no aparece en el runtime.");
        return;
    }

    SEL selector = sel_registerName("emitSampleBuffer:");
    VCMInstallClassHook(baseClass, baseClass, selector);

    int classCount = objc_getClassList(NULL, 0);
    if (classCount <= 0) return;

    Class __unsafe_unretained *classes =
        (__unsafe_unretained Class *)calloc((size_t)classCount, sizeof(Class));
    if (!classes) return;

    classCount = objc_getClassList(classes, classCount);
    for (int index = 0; index < classCount; index++) {
        Class candidate = classes[index];
        if (!VCMIsSubclassOfClass(candidate, baseClass)) continue;
        VCMInstallClassHook(candidate, baseClass, selector);
    }
    free(classes);

    uint32_t installed = atomic_load_explicit(&g_vcmHookCount, memory_order_acquire);
    if (installed > 0) {
        NSLog(@"[VCam Pro/MediaServer] Total de hooks de salida instalados: %u.",
              installed);
        VCMReportEngineStatus(@"hook_installed",
            [NSString stringWithFormat:@"Hook instalado en %u clase(s) BWNodeOutput.", installed]);
    } else {
        VCMReportEngineStatus(@"waiting_for_hook",
            @"BWNodeOutput existe, pero aún no se encontró un método emitSampleBuffer: compatible.");
    }
}

static void VCMScheduleInstallScan(void) {
    if (atomic_exchange_explicit(&g_vcmInstallQueued, 1, memory_order_acq_rel) != 0) return;
    dispatch_async(g_vcmInstallQueue, ^{
        atomic_store_explicit(&g_vcmInstallQueued, 0, memory_order_release);
        VCMInstallMediaGraphHooks();
    });
}

static void VCMImageDidLoad(const struct mach_header *header, intptr_t slide) {
    VCMScheduleInstallScan();
}

static void VCMScheduleRetry(NSUInteger attempt) {
    if (attempt > 20) {
        if (atomic_load_explicit(&g_vcmHookCount, memory_order_acquire) == 0) {
            VCMReportEngineStatus(@"hook_not_found",
                @"No se encontró un hook BWNodeOutput compatible después de los reintentos.");
        }
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.5 * NSEC_PER_SEC)),
                   g_vcmInstallQueue, ^{
        VCMInstallMediaGraphHooks();
        if (atomic_load_explicit(&g_vcmHookCount, memory_order_acquire) == 0) {
            VCMScheduleRetry(attempt + 1);
        }
    });
}

__attribute__((constructor))
static void VCamMediaServerInitialize(void) {
    @autoreleasepool {
        NSString *processName = NSProcessInfo.processInfo.processName.lowercaseString;
        if (![processName isEqualToString:@"mediaserverd"]) return;

        g_vcmInstallQueue = dispatch_queue_create("com.vcam.pro.mediaserver.hooks",
                                                  DISPATCH_QUEUE_SERIAL);
        g_vcmStatusQueue = dispatch_queue_create("com.vcam.pro.mediaserver.status",
                                                 DISPATCH_QUEUE_SERIAL);
        g_vcmHookLock = [[NSLock alloc] init];

        NSLog(@"[VCam Pro/MediaServer] Dylib cargada dentro de mediaserverd.");
        VCMReportEngineStatus(@"loaded",
            @"VCamMediaServer se cargó dentro del proceso mediaserverd.");
        [[VCamMediaServerSource sharedSource] startMonitoring];

        _dyld_register_func_for_add_image(VCMImageDidLoad);
        VCMScheduleInstallScan();
        VCMScheduleRetry(0);
    }
}
