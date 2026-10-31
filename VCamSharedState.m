#import "VCamSharedState.h"

#import <CoreFoundation/CoreFoundation.h>
#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <unistd.h>
#import <string.h>
#import <sys/time.h>
#import <stdlib.h>
#import <math.h>
#import <stdio.h>

static NSString * const kVCamDarwinNotification = @"com.vcam.pro.state.changed";
static const uint16_t kVCamIPCPort = 47831;

static BOOL VCamSendAll(int socketFD, const void *bytes, size_t length) {
    const uint8_t *cursor = (const uint8_t *)bytes;
    size_t sent = 0;

    while (sent < length) {
        ssize_t amount = send(socketFD, cursor + sent, length - sent, 0);
        if (amount < 0) {
            if (errno == EINTR) continue;
            return NO;
        }
        if (amount == 0) return NO;
        sent += (size_t)amount;
    }

    return YES;
}

@interface VCamSharedState () {
    NSRecursiveLock *_stateLock;
    dispatch_queue_t _clientQueue;
    dispatch_source_t _acceptSource;
    int _serverFD;

    BOOL _enabled;
    NSString *_mediaPath;
    NSString *_mediaType;
    NSString *_mediaExtension;
    NSInteger _mediaRevision;
    NSInteger _stateRevision;
    CGFloat _zoom;
    CGFloat _offsetX;
    CGFloat _offsetY;
    NSInteger _rotationDegrees;
    CGFloat _buttonX;
    CGFloat _buttonY;
    NSString *_engineStatus;
    NSString *_engineDetail;
    NSUInteger _engineHooks;
    NSUInteger _engineFrames;
    NSTimeInterval _engineLastSeen;
}

- (NSString *)privateDirectory;
- (NSString *)stateFilePath;
- (void)persistLocked;
- (NSDictionary *)snapshotLocked;
- (void)publishChange;
- (BOOL)preparePrivateDirectory:(NSError **)error;
- (void)handleClient:(int)clientFD;
- (void)applyControlDictionary:(NSDictionary *)control;

@end

@implementation VCamSharedState

+ (instancetype)sharedState {
    static VCamSharedState *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VCamSharedState alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _stateLock = [[NSRecursiveLock alloc] init];
        _clientQueue = dispatch_queue_create("com.vcam.pro.ipc.clients", DISPATCH_QUEUE_CONCURRENT);
        _serverFD = -1;
        _zoom = 1.0;
        _rotationDegrees = 0;
        _buttonX = 0.92;
        _buttonY = 0.24;
        _mediaRevision = 0;
        _stateRevision = 0;
        _engineStatus = @"not_reported";
        _engineDetail = @"Esperando confirmación de mediaserverd.";
        _engineHooks = 0;
        _engineFrames = 0;
        _engineLastSeen = 0;

        NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:[self stateFilePath]];
        if ([saved isKindOfClass:[NSDictionary class]]) {
            _enabled = [saved[@"enabled"] boolValue];
            _mediaPath = [saved[@"mediaPath"] isKindOfClass:[NSString class]] ? [saved[@"mediaPath"] copy] : nil;
            _mediaType = [saved[@"mediaType"] isKindOfClass:[NSString class]] ? [saved[@"mediaType"] copy] : nil;
            _mediaExtension = [saved[@"mediaExtension"] isKindOfClass:[NSString class]] ? [saved[@"mediaExtension"] copy] : nil;
            _mediaRevision = [saved[@"mediaRevision"] integerValue];
            _stateRevision = [saved[@"stateRevision"] integerValue];
            _zoom = MAX(0.5, MIN(4.0, [saved[@"zoom"] doubleValue] ?: 1.0));
            _offsetX = MAX(-1.0, MIN(1.0, [saved[@"offsetX"] doubleValue]));
            _offsetY = MAX(-1.0, MIN(1.0, [saved[@"offsetY"] doubleValue]));
            _rotationDegrees = (([saved[@"rotationDegrees"] integerValue] % 360) + 360) % 360;
            _rotationDegrees = ((_rotationDegrees + 45) / 90 * 90) % 360;
            _buttonX = MAX(0.04, MIN(0.96, [saved[@"buttonX"] doubleValue] ?: 0.92));
            _buttonY = MAX(0.04, MIN(0.96, [saved[@"buttonY"] doubleValue] ?: 0.24));
        }
    }
    return self;
}

- (NSString *)privateDirectory {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *base = paths.firstObject ?: NSTemporaryDirectory();
    return [base stringByAppendingPathComponent:@"VCamProShared"];
}

- (NSString *)stateFilePath {
    return [[self privateDirectory] stringByAppendingPathComponent:@"state.plist"];
}

- (BOOL)preparePrivateDirectory:(NSError **)error {
    NSString *directory = [self privateDirectory];
    BOOL isDirectory = NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:directory isDirectory:&isDirectory] && isDirectory) {
        return YES;
    }

    BOOL created = [[NSFileManager defaultManager] createDirectoryAtPath:directory
                                             withIntermediateDirectories:YES
                                                              attributes:@{ NSFilePosixPermissions: @0700 }
                                                                   error:error];
    return created;
}

- (BOOL)isEnabled {
    [_stateLock lock];
    BOOL value = _enabled;
    [_stateLock unlock];
    return value;
}

- (NSString *)mediaType {
    [_stateLock lock];
    NSString *value = [_mediaType copy];
    [_stateLock unlock];
    return value;
}

- (NSString *)mediaExtension {
    [_stateLock lock];
    NSString *value = [_mediaExtension copy];
    [_stateLock unlock];
    return value;
}

- (NSString *)mediaPath {
    [_stateLock lock];
    NSString *value = [_mediaPath copy];
    [_stateLock unlock];
    return value;
}

- (NSInteger)mediaRevision {
    [_stateLock lock];
    NSInteger value = _mediaRevision;
    [_stateLock unlock];
    return value;
}

- (NSInteger)stateRevision {
    [_stateLock lock];
    NSInteger value = _stateRevision;
    [_stateLock unlock];
    return value;
}

- (CGFloat)zoom {
    [_stateLock lock];
    CGFloat value = _zoom;
    [_stateLock unlock];
    return value;
}

- (CGFloat)offsetX {
    [_stateLock lock];
    CGFloat value = _offsetX;
    [_stateLock unlock];
    return value;
}

- (CGFloat)offsetY {
    [_stateLock lock];
    CGFloat value = _offsetY;
    [_stateLock unlock];
    return value;
}

- (NSInteger)rotationDegrees {
    [_stateLock lock];
    NSInteger value = _rotationDegrees;
    [_stateLock unlock];
    return value;
}

- (CGFloat)buttonX {
    [_stateLock lock];
    CGFloat value = _buttonX;
    [_stateLock unlock];
    return value;
}

- (CGFloat)buttonY {
    [_stateLock lock];
    CGFloat value = _buttonY;
    [_stateLock unlock];
    return value;
}

- (NSDictionary *)snapshotLocked {
    return @{
        @"enabled": @(_enabled),
        @"mediaAvailable": @(_mediaPath.length > 0),
        @"mediaType": _mediaType ?: @"",
        @"mediaExtension": _mediaExtension ?: @"mp4",
        @"mediaRevision": @(_mediaRevision),
        @"stateRevision": @(_stateRevision),
        @"zoom": @(_zoom),
        @"offsetX": @(_offsetX),
        @"offsetY": @(_offsetY),
        @"rotationDegrees": @(_rotationDegrees),
        @"buttonX": @(_buttonX),
        @"buttonY": @(_buttonY),
        @"engineStatus": _engineStatus ?: @"not_reported",
        @"engineDetail": _engineDetail ?: @"",
        @"engineHooks": @(_engineHooks),
        @"engineFrames": @(_engineFrames),
        @"engineLastSeen": @(_engineLastSeen)
    };
}

- (void)persistLocked {
    if (![self preparePrivateDirectory:nil]) {
        NSLog(@"[VCam Pro] No se pudo crear el directorio privado de estado.");
        return;
    }

    NSMutableDictionary *dictionary = [[self snapshotLocked] mutableCopy];
    dictionary[@"mediaPath"] = _mediaPath ?: @"";

    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:dictionary
                                                               format:NSPropertyListBinaryFormat_v1_0
                                                              options:0
                                                                error:&error];
    if (!data || ![data writeToFile:[self stateFilePath] options:NSDataWritingAtomic error:&error]) {
        NSLog(@"[VCam Pro] Error guardando estado: %@", error);
    }
}

- (void)publishChange {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)kVCamDarwinNotification,
                                         NULL,
                                         NULL,
                                         YES);
}

- (BOOL)importImage:(UIImage *)image error:(NSError **)error {
    if (!image || !image.CGImage) {
        if (error) *error = [NSError errorWithDomain:@"VCamPro" code:100 userInfo:@{NSLocalizedDescriptionKey: @"La imagen seleccionada no es válida."}];
        return NO;
    }

    NSData *jpeg = UIImageJPEGRepresentation(image, 0.94);
    if (!jpeg) {
        if (error) *error = [NSError errorWithDomain:@"VCamPro" code:101 userInfo:@{NSLocalizedDescriptionKey: @"No se pudo convertir la imagen a JPEG."}];
        return NO;
    }

    if (![self preparePrivateDirectory:error]) return NO;

    NSString *destination = [[self privateDirectory] stringByAppendingPathComponent:@"selected.jpg"];
    if (![jpeg writeToFile:destination options:NSDataWritingAtomic error:error]) return NO;
    chmod(destination.fileSystemRepresentation, 0644);

    [_stateLock lock];
    _mediaPath = [destination copy];
    _mediaType = @"image";
    _mediaExtension = @"jpg";
    _mediaRevision += 1;
    _enabled = YES;
    _stateRevision += 1;
    [self persistLocked];
    [_stateLock unlock];

    [self publishChange];
    NSLog(@"[VCam Pro] Imagen compartida publicada. Revisión: %ld", (long)self.mediaRevision);
    return YES;
}

- (BOOL)importVideoAtURL:(NSURL *)url error:(NSError **)error {
    if (!url.isFileURL) {
        if (error) *error = [NSError errorWithDomain:@"VCamPro" code:102 userInfo:@{NSLocalizedDescriptionKey: @"La URL del vídeo no es un archivo local."}];
        return NO;
    }

    if (![self preparePrivateDirectory:error]) return NO;

    BOOL didStartAccess = NO;
    if ([url respondsToSelector:@selector(startAccessingSecurityScopedResource)]) {
        didStartAccess = [url startAccessingSecurityScopedResource];
    }

    NSString *ext = url.pathExtension.lowercaseString;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789"];
    ext = [[ext componentsSeparatedByCharactersInSet:allowed.invertedSet] componentsJoinedByString:@""];
    if (ext.length == 0 || ext.length > 8) ext = @"mp4";

    NSString *destination = [[self privateDirectory] stringByAppendingPathComponent:[NSString stringWithFormat:@"selected.%@", ext]];
    NSFileManager *manager = [NSFileManager defaultManager];
    [manager removeItemAtPath:destination error:nil];

    NSError *copyError = nil;
    BOOL copied = [manager copyItemAtURL:url toURL:[NSURL fileURLWithPath:destination] error:&copyError];

    if (didStartAccess) [url stopAccessingSecurityScopedResource];

    if (!copied) {
        if (error) *error = copyError;
        return NO;
    }

    chmod(destination.fileSystemRepresentation, 0644);

    [_stateLock lock];
    _mediaPath = [destination copy];
    _mediaType = @"video";
    _mediaExtension = ext;
    _mediaRevision += 1;
    _enabled = YES;
    _stateRevision += 1;
    [self persistLocked];
    [_stateLock unlock];

    [self publishChange];
    NSLog(@"[VCam Pro] Vídeo compartido publicado. Revisión: %ld", (long)self.mediaRevision);
    return YES;
}

- (void)setEnabled:(BOOL)enabled {
    [_stateLock lock];
    _enabled = enabled;
    _stateRevision += 1;
    [self persistLocked];
    [_stateLock unlock];
    [self publishChange];
}

- (void)setTransformWithZoom:(CGFloat)zoom
                    offsetX:(CGFloat)offsetX
                    offsetY:(CGFloat)offsetY
            rotationDegrees:(NSInteger)rotationDegrees {
    NSInteger normalizedRotation = ((rotationDegrees % 360) + 360) % 360;
    normalizedRotation = ((normalizedRotation + 45) / 90 * 90) % 360;

    [_stateLock lock];
    _zoom = MAX(0.5, MIN(4.0, isfinite(zoom) ? zoom : 1.0));
    _offsetX = MAX(-1.0, MIN(1.0, isfinite(offsetX) ? offsetX : 0.0));
    _offsetY = MAX(-1.0, MIN(1.0, isfinite(offsetY) ? offsetY : 0.0));
    _rotationDegrees = normalizedRotation;
    _stateRevision += 1;
    [self persistLocked];
    [_stateLock unlock];
    [self publishChange];
}

- (void)adjustOffsetX:(CGFloat)deltaX offsetY:(CGFloat)deltaY {
    [_stateLock lock];
    _offsetX = MAX(-1.0, MIN(1.0, _offsetX + deltaX));
    _offsetY = MAX(-1.0, MIN(1.0, _offsetY + deltaY));
    _stateRevision += 1;
    [self persistLocked];
    [_stateLock unlock];
    [self publishChange];
}

- (void)adjustZoomBy:(CGFloat)delta {
    [_stateLock lock];
    _zoom = MAX(0.5, MIN(4.0, _zoom + delta));
    _stateRevision += 1;
    [self persistLocked];
    [_stateLock unlock];
    [self publishChange];
}

- (void)resetImageTransform {
    [_stateLock lock];
    _zoom = 1.0;
    _offsetX = 0.0;
    _offsetY = 0.0;
    _stateRevision += 1;
    [self persistLocked];
    [_stateLock unlock];
    [self publishChange];
}

- (void)setButtonNormalizedX:(CGFloat)x y:(CGFloat)y {
    [_stateLock lock];
    _buttonX = MAX(0.04, MIN(0.96, x));
    _buttonY = MAX(0.04, MIN(0.96, y));
    _stateRevision += 1;
    [self persistLocked];
    [_stateLock unlock];
    [self publishChange];
}

- (BOOL)startServer {
    if (_acceptSource) return YES;

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        NSLog(@"[VCam Pro] No se pudo crear socket IPC: %s", strerror(errno));
        return NO;
    }

    int reuse = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_port = htons(kVCamIPCPort);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(fd, 8) != 0) {
        NSLog(@"[VCam Pro] No se pudo iniciar IPC en puerto %d: %s", kVCamIPCPort, strerror(errno));
        close(fd);
        return NO;
    }

    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    _serverFD = fd;
    dispatch_queue_t acceptQueue = dispatch_queue_create("com.vcam.pro.ipc.accept", DISPATCH_QUEUE_SERIAL);
    _acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, acceptQueue);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_acceptSource, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        while (YES) {
            struct sockaddr_in peer;
            socklen_t peerLength = sizeof(peer);
            int clientFD = accept(fd, (struct sockaddr *)&peer, &peerLength);
            if (clientFD < 0) {
                if (errno == EINTR) continue;
                break;
            }

            dispatch_async(strongSelf->_clientQueue, ^{
                [strongSelf handleClient:clientFD];
                close(clientFD);
            });
        }
    });

    dispatch_source_set_cancel_handler(_acceptSource, ^{
        close(fd);
    });
    dispatch_resume(_acceptSource);

    NSLog(@"[VCam Pro] Servidor IPC escuchando en 127.0.0.1:%d", kVCamIPCPort);
    return YES;
}

- (void)applyControlDictionary:(NSDictionary *)control {
    if (![control isKindOfClass:[NSDictionary class]]) return;

    [_stateLock lock];
    NSNumber *enabled = control[@"enabled"];
    NSNumber *zoom = control[@"zoom"];
    NSNumber *offsetX = control[@"offsetX"];
    NSNumber *offsetY = control[@"offsetY"];
    NSNumber *rotationDegrees = control[@"rotationDegrees"];
    NSNumber *buttonX = control[@"buttonX"];
    NSNumber *buttonY = control[@"buttonY"];

    if ([enabled isKindOfClass:[NSNumber class]]) _enabled = enabled.boolValue;
    if ([zoom isKindOfClass:[NSNumber class]] && isfinite(zoom.doubleValue)) {
        _zoom = MAX(0.5, MIN(4.0, zoom.doubleValue));
    }
    if ([offsetX isKindOfClass:[NSNumber class]] && isfinite(offsetX.doubleValue)) {
        _offsetX = MAX(-1.0, MIN(1.0, offsetX.doubleValue));
    }
    if ([offsetY isKindOfClass:[NSNumber class]] && isfinite(offsetY.doubleValue)) {
        _offsetY = MAX(-1.0, MIN(1.0, offsetY.doubleValue));
    }
    if ([rotationDegrees isKindOfClass:[NSNumber class]]) {
        NSInteger normalized = ((rotationDegrees.integerValue % 360) + 360) % 360;
        _rotationDegrees = ((normalized + 45) / 90 * 90) % 360;
    }
    if ([buttonX isKindOfClass:[NSNumber class]] && isfinite(buttonX.doubleValue)) {
        _buttonX = MAX(0.04, MIN(0.96, buttonX.doubleValue));
    }
    if ([buttonY isKindOfClass:[NSNumber class]] && isfinite(buttonY.doubleValue)) {
        _buttonY = MAX(0.04, MIN(0.96, buttonY.doubleValue));
    }

    _stateRevision += 1;
    [self persistLocked];
    [_stateLock unlock];
    [self publishChange];
}

- (void)handleClient:(int)clientFD {
    int noSigPipe = 1;
    setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));

    struct timeval timeout;
    timeout.tv_sec = 120;
    timeout.tv_usec = 0;
    setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

    const NSUInteger maximumHeaderSize = 16 * 1024;
    NSMutableData *requestData = [NSMutableData data];
    NSData *separator = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t receiveBuffer[64 * 1024];
    NSRange headerRange = NSMakeRange(NSNotFound, 0);

    while (headerRange.location == NSNotFound) {
        ssize_t amount = recv(clientFD, receiveBuffer, sizeof(receiveBuffer), 0);
        if (amount < 0) {
            if (errno == EINTR) continue;
            return;
        }
        if (amount == 0) return;
        [requestData appendBytes:receiveBuffer length:(NSUInteger)amount];
        headerRange = [requestData rangeOfData:separator options:0 range:NSMakeRange(0, requestData.length)];
        if (headerRange.location == NSNotFound && requestData.length > maximumHeaderSize) return;
        if (headerRange.location != NSNotFound && headerRange.location > maximumHeaderSize) return;
    }

    NSData *headerData = [requestData subdataWithRange:NSMakeRange(0, headerRange.location)];
    NSString *headerText = [[NSString alloc] initWithData:headerData encoding:NSUTF8StringEncoding];
    if (!headerText) return;

    NSArray<NSString *> *lines = [headerText componentsSeparatedByString:@"\r\n"];
    NSArray<NSString *> *firstLineParts = lines.firstObject ? [lines.firstObject componentsSeparatedByString:@" "] : @[];
    if (firstLineParts.count < 2) return;

    NSString *method = firstLineParts[0].uppercaseString;
    NSString *requestPath = firstLineParts[1];
    NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary dictionary];
    for (NSUInteger index = 1; index < lines.count; index++) {
        NSString *line = lines[index];
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        NSString *key = [[[line substringToIndex:colon.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] lowercaseString];
        NSString *value = [[line substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (key.length) headers[key] = value;
    }

    unsigned long long contentLength = 0;
    NSString *lengthString = headers[@"content-length"];
    if (lengthString.length) {
        const char *text = lengthString.UTF8String;
        char *endPointer = NULL;
        errno = 0;
        unsigned long long parsed = strtoull(text, &endPointer, 10);
        if (errno == 0 && endPointer && *endPointer == '\0') contentLength = parsed;
        else return;
    }

    NSUInteger bodyOffset = NSMaxRange(headerRange);
    NSUInteger initialBodyLength = requestData.length > bodyOffset ? requestData.length - bodyOffset : 0;
    const uint8_t *initialBody = initialBodyLength ? (const uint8_t *)requestData.bytes + bodyOffset : NULL;

    BOOL isGET = [method isEqualToString:@"GET"];
    BOOL isPOST = [method isEqualToString:@"POST"];

    if (isGET && [requestPath isEqualToString:@"/health"]) {
        NSData *body = [@"VCam IPC OK" dataUsingEncoding:NSUTF8StringEncoding];
        NSString *responseHeader = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n", (unsigned long)body.length];
        VCamSendAll(clientFD, responseHeader.UTF8String, responseHeader.length);
        VCamSendAll(clientFD, body.bytes, body.length);
        return;
    }

    if (isGET && [requestPath isEqualToString:@"/state"]) {
        [_stateLock lock];
        NSDictionary *snapshot = [[self snapshotLocked] copy];
        [_stateLock unlock];
        NSError *jsonError = nil;
        NSData *body = [NSJSONSerialization dataWithJSONObject:snapshot options:0 error:&jsonError];
        if (!body) body = [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
        NSString *responseHeader = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n", (unsigned long)body.length];
        if (VCamSendAll(clientFD, responseHeader.UTF8String, responseHeader.length)) {
            VCamSendAll(clientFD, body.bytes, body.length);
        }
        return;
    }

    if (isGET && ([requestPath isEqualToString:@"/media"] || [requestPath hasPrefix:@"/media?"])) {
        NSInteger requestedRevision = 0;
        if ([requestPath containsString:@"?"]) {
            NSURLComponents *components = [NSURLComponents componentsWithString:
                [@"http://127.0.0.1" stringByAppendingString:requestPath]];
            for (NSURLQueryItem *item in components.queryItems) {
                if ([item.name isEqualToString:@"revision"]) {
                    requestedRevision = item.value.integerValue;
                    break;
                }
            }
        }

        [_stateLock lock];
        NSInteger currentRevision = _mediaRevision;
        NSString *mediaPath = [_mediaPath copy];
        [_stateLock unlock];

        if (requestedRevision > 0 && requestedRevision != currentRevision) {
            NSData *body = [@"Media revision changed; refresh state and retry." dataUsingEncoding:NSUTF8StringEncoding];
            NSString *responseHeader = [NSString stringWithFormat:
                @"HTTP/1.1 409 Conflict\r\nCache-Control: no-store\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n",
                (unsigned long)body.length];
            VCamSendAll(clientFD, responseHeader.UTF8String, responseHeader.length);
            VCamSendAll(clientFD, body.bytes, body.length);
            return;
        }
        if (mediaPath.length == 0) {
            NSData *body = [@"No media selected" dataUsingEncoding:NSUTF8StringEncoding];
            NSString *responseHeader = [NSString stringWithFormat:@"HTTP/1.1 404 Not Found\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n", (unsigned long)body.length];
            VCamSendAll(clientFD, responseHeader.UTF8String, responseHeader.length);
            VCamSendAll(clientFD, body.bytes, body.length);
            return;
        }

        int fileFD = open(mediaPath.fileSystemRepresentation, O_RDONLY);
        if (fileFD < 0) {
            NSData *body = [@"Media unavailable" dataUsingEncoding:NSUTF8StringEncoding];
            NSString *responseHeader = [NSString stringWithFormat:@"HTTP/1.1 404 Not Found\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n", (unsigned long)body.length];
            VCamSendAll(clientFD, responseHeader.UTF8String, responseHeader.length);
            VCamSendAll(clientFD, body.bytes, body.length);
            return;
        }

        struct stat fileInfo;
        if (fstat(fileFD, &fileInfo) != 0 || fileInfo.st_size <= 0) {
            close(fileFD);
            return;
        }
        NSString *responseHeader = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nCache-Control: no-store\r\nContent-Length: %lld\r\nConnection: close\r\n\r\n", (long long)fileInfo.st_size];
        if (!VCamSendAll(clientFD, responseHeader.UTF8String, responseHeader.length)) {
            close(fileFD);
            return;
        }
        uint8_t fileBuffer[64 * 1024];
        while (YES) {
            ssize_t amount = read(fileFD, fileBuffer, sizeof(fileBuffer));
            if (amount < 0) {
                if (errno == EINTR) continue;
                break;
            }
            if (amount == 0) break;
            if (!VCamSendAll(clientFD, fileBuffer, (size_t)amount)) break;
        }
        close(fileFD);
        return;
    }

    if (isPOST && [requestPath isEqualToString:@"/engine-status"]) {
        const unsigned long long maximumStatusSize = 8 * 1024;
        if (contentLength == 0 || contentLength > maximumStatusSize ||
            initialBodyLength > contentLength) return;

        NSMutableData *body = [NSMutableData dataWithBytes:initialBody
                                                    length:initialBodyLength];
        while (body.length < contentLength) {
            size_t remaining = (size_t)(contentLength - body.length);
            ssize_t amount = recv(clientFD, receiveBuffer,
                                  MIN(sizeof(receiveBuffer), remaining), 0);
            if (amount < 0) {
                if (errno == EINTR) continue;
                return;
            }
            if (amount == 0) return;
            [body appendBytes:receiveBuffer length:(NSUInteger)amount];
        }

        NSError *jsonError = nil;
        id object = [NSJSONSerialization JSONObjectWithData:body options:0 error:&jsonError];
        if (![object isKindOfClass:[NSDictionary class]]) {
        NSData *responseBody = [@"OK" dataUsingEncoding:NSUTF8StringEncoding];
            NSString *responseHeader = [NSString stringWithFormat:
                @"HTTP/1.1 400 Bad Request\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n",
                (unsigned long)responseBody.length];
            VCamSendAll(clientFD, responseHeader.UTF8String, responseHeader.length);
            VCamSendAll(clientFD, responseBody.bytes, responseBody.length);
            return;
        }

        NSDictionary *report = (NSDictionary *)object;
        NSString *status = [report[@"status"] isKindOfClass:[NSString class]]
            ? report[@"status"] : @"unknown";
        NSString *detail = [report[@"detail"] isKindOfClass:[NSString class]]
            ? report[@"detail"] : @"";
        if (status.length > 64) status = [status substringToIndex:64];
        if (detail.length > 512) detail = [detail substringToIndex:512];

        [_stateLock lock];
        _engineStatus = [status copy];
        _engineDetail = [detail copy];
        if ([report[@"hooks"] isKindOfClass:[NSNumber class]]) {
            _engineHooks = MAX(0, [report[@"hooks"] unsignedIntegerValue]);
        }
        if ([report[@"frames"] isKindOfClass:[NSNumber class]]) {
            _engineFrames = MAX(0, [report[@"frames"] unsignedIntegerValue]);
        }
        _engineLastSeen = [NSDate date].timeIntervalSince1970;
        [_stateLock unlock];

        NSData *responseBody = [@"{\"ok\":true}" dataUsingEncoding:NSUTF8StringEncoding];
        NSString *responseHeader = [NSString stringWithFormat:
            @"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n",
            (unsigned long)responseBody.length];
        VCamSendAll(clientFD, responseHeader.UTF8String, responseHeader.length);
        VCamSendAll(clientFD, responseBody.bytes, responseBody.length);
        return;
    }

    if (isPOST && [requestPath isEqualToString:@"/control"]) {
        const unsigned long long maximumControlSize = 32 * 1024;
        if (contentLength == 0 || contentLength > maximumControlSize || initialBodyLength > contentLength) return;
        NSMutableData *body = [NSMutableData dataWithBytes:initialBody length:initialBodyLength];
        while (body.length < contentLength) {
            size_t remaining = (size_t)(contentLength - body.length);
            ssize_t amount = recv(clientFD, receiveBuffer, MIN(sizeof(receiveBuffer), remaining), 0);
            if (amount < 0) {
                if (errno == EINTR) continue;
                return;
            }
            if (amount == 0) return;
            [body appendBytes:receiveBuffer length:(NSUInteger)amount];
        }
        NSError *jsonError = nil;
        id object = [NSJSONSerialization JSONObjectWithData:body options:0 error:&jsonError];
        if (![object isKindOfClass:[NSDictionary class]]) {
            NSData *responseBody = [@"Invalid control JSON" dataUsingEncoding:NSUTF8StringEncoding];
            NSString *responseHeader = [NSString stringWithFormat:@"HTTP/1.1 400 Bad Request\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n", (unsigned long)responseBody.length];
            VCamSendAll(clientFD, responseHeader.UTF8String, responseHeader.length);
            VCamSendAll(clientFD, responseBody.bytes, responseBody.length);
            return;
        }
        [self applyControlDictionary:object];
        NSData *responseBody = [@"{\"ok\":true}" dataUsingEncoding:NSUTF8StringEncoding];
        NSString *responseHeader = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n", (unsigned long)responseBody.length];
        VCamSendAll(clientFD, responseHeader.UTF8String, responseHeader.length);
        VCamSendAll(clientFD, responseBody.bytes, responseBody.length);
        return;
    }

    if (isPOST && [requestPath hasPrefix:@"/upload?"]) {
        const unsigned long long maximumUploadSize = 1024ULL * 1024ULL * 1024ULL;
        if (contentLength == 0 || contentLength > maximumUploadSize || initialBodyLength > contentLength) return;

        NSURLComponents *components = [NSURLComponents componentsWithString:[@"http://127.0.0.1" stringByAppendingString:requestPath]];
        NSMutableDictionary *query = [NSMutableDictionary dictionary];
        for (NSURLQueryItem *item in components.queryItems) {
            if (item.name && item.value) query[item.name] = item.value;
        }
        NSString *mediaType = [query[@"type"] lowercaseString];
        NSString *extension = [query[@"ext"] lowercaseString];
        NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789"];
        extension = [[extension componentsSeparatedByCharactersInSet:allowed.invertedSet] componentsJoinedByString:@""];
        if (!([mediaType isEqualToString:@"image"] || [mediaType isEqualToString:@"video"]) || extension.length == 0 || extension.length > 8) return;
        if ([mediaType isEqualToString:@"image"] && contentLength > 64ULL * 1024ULL * 1024ULL) return;

        NSString *temporaryName = [NSString stringWithFormat:@"incoming_%@.tmp", NSUUID.UUID.UUIDString];
        NSString *temporaryPath = [[self privateDirectory] stringByAppendingPathComponent:temporaryName];
        if (![self preparePrivateDirectory:nil]) return;
        int outputFD = open(temporaryPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL, 0600);
        if (outputFD < 0) return;

        unsigned long long written = 0;
        BOOL writeOK = YES;
        if (initialBodyLength > 0) {
            size_t offset = 0;
            while (offset < initialBodyLength) {
                ssize_t amount = write(outputFD, initialBody + offset, initialBodyLength - offset);
                if (amount < 0) {
                    if (errno == EINTR) continue;
                    writeOK = NO;
                    break;
                }
                if (amount == 0) { writeOK = NO; break; }
                offset += (size_t)amount;
                written += (unsigned long long)amount;
            }
        }
        while (writeOK && written < contentLength) {
            size_t remaining = (size_t)MIN((unsigned long long)sizeof(receiveBuffer), contentLength - written);
            ssize_t amount = recv(clientFD, receiveBuffer, remaining, 0);
            if (amount < 0) {
                if (errno == EINTR) continue;
                writeOK = NO;
                break;
            }
            if (amount == 0) { writeOK = NO; break; }
            size_t offset = 0;
            while (offset < (size_t)amount) {
                ssize_t amountWritten = write(outputFD, receiveBuffer + offset, (size_t)amount - offset);
                if (amountWritten < 0) {
                    if (errno == EINTR) continue;
                    writeOK = NO;
                    break;
                }
                if (amountWritten == 0) { writeOK = NO; break; }
                offset += (size_t)amountWritten;
                written += (unsigned long long)amountWritten;
            }
        }
        fsync(outputFD);
        close(outputFD);

        if (!writeOK || written != contentLength) {
            unlink(temporaryPath.fileSystemRepresentation);
            return;
        }

        NSString *finalName = [NSString stringWithFormat:@"selected_%@.%@", NSUUID.UUID.UUIDString, extension];
        NSString *finalPath = [[self privateDirectory] stringByAppendingPathComponent:finalName];
        if (rename(temporaryPath.fileSystemRepresentation, finalPath.fileSystemRepresentation) != 0) {
            unlink(temporaryPath.fileSystemRepresentation);
            return;
        }
        chmod(finalPath.fileSystemRepresentation, 0644);

        [_stateLock lock];
        _mediaPath = [finalPath copy];
        _mediaType = mediaType;
        _mediaExtension = extension;
        _mediaRevision += 1;
        _enabled = YES;
        _stateRevision += 1;
        [self persistLocked];
        [_stateLock unlock];
        [self publishChange];
        // Keep previous revisions on disk while app processes may still be
        // downloading a previously published media revision.

        NSData *responseBody = [@"{\"ok\":true}" dataUsingEncoding:NSUTF8StringEncoding];
        NSString *responseHeader = [NSString stringWithFormat:@"HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n", (unsigned long)responseBody.length];
        VCamSendAll(clientFD, responseHeader.UTF8String, responseHeader.length);
        VCamSendAll(clientFD, responseBody.bytes, responseBody.length);
        NSLog(@"[VCam Pro] Medio recibido por IPC (%@, %@, %llu bytes).", mediaType, extension, contentLength);
        return;
    }

    const char *message = isGET || isPOST ? "Not Found" : "Method Not Allowed";
    int status = isGET || isPOST ? 404 : 405;
    NSData *responseBody = [[NSString stringWithUTF8String:message] dataUsingEncoding:NSUTF8StringEncoding];
    NSString *responseHeader = [NSString stringWithFormat:@"HTTP/1.1 %d %@\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n", status, status == 404 ? @"Not Found" : @"Method Not Allowed", (unsigned long)responseBody.length];
    VCamSendAll(clientFD, responseHeader.UTF8String, responseHeader.length);
    VCamSendAll(clientFD, responseBody.bytes, responseBody.length);
}

@end
