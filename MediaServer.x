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
static uint32_t g_vcmLastReportedFrames = 0;
static _Atomic(uint32_t) g_vcmUnreplacedCount = 0;
static const uint16_t kVCMStatusPort = 47831;

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
        BOOL progressed = frames >= g_vcmLastReportedFrames + 120;
        if (!changed && !progressed) return;

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
    VCMEmitSampleBufferFunction original = VCMOriginalForObject(object, selector);

    if (sampleBuffer && original) {
        SEL mediaTypeSelector = sel_registerName("mediaType");
        if ([object respondsToSelector:mediaTypeSelector]) {
            uint32_t mediaType =
                ((uint32_t (*)(id, SEL))objc_msgSend)(object, mediaTypeSelector);

            if (mediaType == 'vide') {
                CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
                if (imageBuffer &&
                    [[VCamMediaServerSource sharedSource]
                        renderNextFrameIntoPixelBuffer:(CVPixelBufferRef)imageBuffer]) {
                    CVBufferSetAttachment(imageBuffer,
                                          kVCMSystemReplacementAttachment,
                                          kCFBooleanTrue,
                                          kCVAttachmentMode_ShouldPropagate);
                    CMSetAttachment(sampleBuffer,
                                    kVCMSystemReplacementAttachment,
                                    kCFBooleanTrue,
                                    kCMAttachmentMode_ShouldPropagate);

                    uint32_t count = atomic_fetch_add_explicit(&g_vcmReplacementCount,
                                                               1,
                                                               memory_order_relaxed) + 1;
                    if (count <= 3 || count % 600 == 0) {
                        NSLog(@"[VCam Pro/MediaServer] Fotograma de cámara sustituido (#%u).",
                              count);
                    }
                    if (count <= 3 || count % 120 == 0) {
                        VCMReportEngineStatus(@"frames_replaced",
                            [NSString stringWithFormat:@"VCam ya sustituyó %u fotogramas de cámara.", count]);
                    }
                } else if (imageBuffer) {
                    uint32_t attempts = atomic_fetch_add_explicit(&g_vcmUnreplacedCount,
                                                                  1,
                                                                  memory_order_relaxed) + 1;
                    if (attempts == 1 || attempts % 120 == 0) {
                        VCMReportEngineStatus(@"hook_active_no_frame",
                            @"El hook recibe fotogramas, pero el medio virtual todavía no está listo para renderizarse.");
                    }
                }
            }
        }
    }

    if (original) {
        original(object, selector, sampleBuffer);
    } else {
        NSLog(@"[VCam Pro/MediaServer] No se encontró IMP original para %@.",
              NSStringFromClass(object_getClass(object)));
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
