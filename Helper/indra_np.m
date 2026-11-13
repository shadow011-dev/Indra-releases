#import <Foundation/Foundation.h>
#import <dlfcn.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <pthread.h>
#include <math.h>
#include <signal.h>

typedef void (^InfoBlock)(NSDictionary *);
typedef void (^BoolBlock)(Boolean);
typedef void (^ClientBlock)(id);

static void (*MRGetInfo)(dispatch_queue_t, InfoBlock);
static void (*MRGetIsPlaying)(dispatch_queue_t, BoolBlock);
static void (*MRGetClient)(dispatch_queue_t, ClientBlock);
static NSString *(*MRClientBundle)(id);
static NSString *(*MRClientParent)(id);
static void (*MRRegister)(dispatch_queue_t);
static Boolean (*MRSend)(int, id);
static void (*MRSetElapsed)(double);

static dispatch_queue_t gQueue;
static BOOL gPending = NO;
static NSString *gLastIdentity = @"";
static NSString *gLastArtHash = @"";
static dispatch_source_t gTimer;

static void writeRaw(const char *bytes, size_t left) {
    while (left > 0) {
        ssize_t n = write(1, bytes, left);
        if (n <= 0) return;
        bytes += n;
        left -= (size_t)n;
    }
}

// v490: JSON cannot hold NaN or Infinity (a live stream reports an endless duration), and NSJSONSerialization answers that
// with an Objective-C exception that nothing caught: the helper aborted on every start for as long as such a song was
// the current one, which Indra reported as "the Now Playing helper keeps stopping".
static double finiteValue(double v) {
    return isfinite(v) ? v : 0;
}

static void writeLine(NSDictionary *dict) {
    NSData *json = nil;
    @try {
        json = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
    } @catch (NSException *e) {
        fprintf(stderr, "json: %s\n", e.reason.UTF8String ?: "unknown");
        json = nil;
    }
    if (!json) return;
    NSMutableData *line = [json mutableCopy];
    [line appendBytes:"\n" length:1];
    writeRaw(line.bytes, line.length);
}

// What the helper was doing when it died, written to stderr by the signal handler (Indra copies stderr to nowplaying.log).
static char gStage[160] = "start";
static void setStage(const char *text) {
    strlcpy(gStage, text ? text : "", sizeof gStage);
}

static void crashHandler(int sig) {
    const char head[] = "crash: signal ";
    char num[8];
    int n = sig, i = 0;
    char rev[8];
    if (n == 0) rev[i++] = '0';
    while (n > 0 && i < 7) { rev[i++] = (char)('0' + n % 10); n /= 10; }
    int j = 0;
    while (i > 0) num[j++] = rev[--i];
    num[j] = 0;
    write(2, head, sizeof head - 1);
    write(2, num, strlen(num));
    write(2, " during ", 8);
    write(2, gStage, strlen(gStage));
    write(2, "\n", 1);
    signal(sig, SIG_DFL);
    raise(sig);
}

static void uncaughtException(NSException *e) {
    fprintf(stderr, "crash: exception %s: %s during %s\n", e.name.UTF8String ?: "?", e.reason.UTF8String ?: "?", gStage);
    fflush(stderr);
}

static NSString *normalizedBundle(NSString *bundle, NSString *parent) {
    NSString *chosen = (parent.length > 0) ? parent : bundle;
    if (chosen.length == 0) return @"";
    // WebKit helper processes belong to Safari.
    if ([chosen hasPrefix:@"com.apple.WebKit"]) return @"com.apple.Safari";
    // Chromium style helpers: com.google.Chrome.helper.Renderer -> com.google.Chrome
    NSRange helper = [chosen rangeOfString:@".helper"];
    if (helper.location != NSNotFound && helper.location > 0) {
        chosen = [chosen substringToIndex:helper.location];
    }
    return chosen;
}

static NSString *stringValue(id value) {
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

static double numberValue(id value) {
    return [value isKindOfClass:[NSNumber class]] ? finiteValue([value doubleValue]) : 0;
}

static void emit(NSString *bundle, NSDictionary *info, BOOL playingFlag) {
    setStage("emit");
    if (![info isKindOfClass:[NSDictionary class]]) info = @{};
    NSString *title = stringValue(info[@"kMRMediaRemoteNowPlayingInfoTitle"]);
    BOOL has = (bundle.length > 0) && (title.length > 0 || playingFlag);
    if (!has) {
        writeLine(@{@"has": @NO});
        return;
    }
    NSString *artist = stringValue(info[@"kMRMediaRemoteNowPlayingInfoArtist"]);
    NSString *album = stringValue(info[@"kMRMediaRemoteNowPlayingInfoAlbum"]);
    double duration = numberValue(info[@"kMRMediaRemoteNowPlayingInfoDuration"]);
    double elapsed = numberValue(info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]);
    id rateValue = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"];
    double rate = [rateValue isKindOfClass:[NSNumber class]] ? finiteValue([rateValue doubleValue]) : (playingFlag ? 1 : 0);
    BOOL playing = playingFlag;

    double position = elapsed;
    id stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
    if (playing && [stamp isKindOfClass:[NSDate class]]) {
        double age = [[NSDate date] timeIntervalSinceDate:stamp];
        if (age > 0 && age < 86400) position = elapsed + age * (rate > 0 ? rate : 1);
    }
    position = finiteValue(position);
    if (position < 0) position = 0;
    if (duration > 0 && position > duration) position = duration;

    NSMutableDictionary *out = [@{
        @"has": @YES,
        @"bundle": bundle,
        @"title": title,
        @"artist": artist,
        @"album": album,
        @"duration": @(duration),
        @"position": @(position),
        @"rate": @(rate),
        @"playing": @(playing),
    } mutableCopy];

    NSString *identity = [NSString stringWithFormat:@"%@|%@|%@|%@", bundle, title, artist, album];
    id art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
    if ([art isKindOfClass:[NSData class]] && [(NSData *)art length] > 0) {
        NSString *hash = [NSString stringWithFormat:@"%lu-%lu", (unsigned long)[(NSData *)art length], (unsigned long)[(NSData *)art hash]];
        if (![hash isEqualToString:gLastArtHash] || ![identity isEqualToString:gLastIdentity]) {
            out[@"art"] = [(NSData *)art base64EncodedStringWithOptions:0];
            gLastArtHash = hash;
        }
    } else if (![identity isEqualToString:gLastIdentity]) {
        gLastArtHash = @"";
    }
    gLastIdentity = identity;
    writeLine(out);
}

static void poll(void) {
    setStage("poll: client");
    MRGetClient(gQueue, ^(id client) {
        @try {
            NSString *bundle = @"";
            if (client) {
                setStage("poll: client bundle");
                NSString *own = MRClientBundle ? MRClientBundle(client) : nil;
                NSString *parent = MRClientParent ? MRClientParent(client) : nil;
                if (![own isKindOfClass:[NSString class]]) own = nil;
                if (![parent isKindOfClass:[NSString class]]) parent = nil;
                bundle = normalizedBundle(own, parent);
            }
            setStage("poll: info");
            MRGetInfo(gQueue, ^(NSDictionary *info) {
                @try {
                    setStage("poll: playing flag");
                    MRGetIsPlaying(gQueue, ^(Boolean playing) {
                        @try {
                            emit(bundle, info ?: @{}, playing ? YES : NO);
                        } @catch (NSException *e) {
                            fprintf(stderr, "emit: %s: %s\n", e.name.UTF8String ?: "?", e.reason.UTF8String ?: "?");
                        }
                    });
                } @catch (NSException *e) {
                    fprintf(stderr, "playing flag: %s: %s\n", e.name.UTF8String ?: "?", e.reason.UTF8String ?: "?");
                }
            });
        } @catch (NSException *e) {
            fprintf(stderr, "client: %s: %s\n", e.name.UTF8String ?: "?", e.reason.UTF8String ?: "?");
        }
    });
}

// Coalesces bursts of notifications into one query.
static void schedule(double delay) {
    dispatch_async(gQueue, ^{
        if (gPending) return;
        gPending = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), gQueue, ^{
            gPending = NO;
            poll();
        });
    });
}

static void handleCommand(const char *line) {
    if (strncmp(line, "play", 4) == 0 && line[4] == 0) { if (MRSend) MRSend(0, nil); }
    else if (strcmp(line, "pause") == 0) { if (MRSend) MRSend(1, nil); }
    else if (strcmp(line, "toggle") == 0) { if (MRSend) MRSend(2, nil); }
    else if (strcmp(line, "stop") == 0) { if (MRSend) MRSend(3, nil); }
    else if (strcmp(line, "next") == 0) { if (MRSend) MRSend(4, nil); }
    else if (strcmp(line, "prev") == 0) { if (MRSend) MRSend(5, nil); }
    else if (strncmp(line, "seek ", 5) == 0) { if (MRSetElapsed) MRSetElapsed(atof(line + 5)); }
    schedule(0.3);
}

static void *readCommands(void *unused) {
    char buffer[256];
    while (fgets(buffer, sizeof buffer, stdin)) {
        size_t n = strlen(buffer);
        while (n > 0 && (buffer[n - 1] == '\n' || buffer[n - 1] == '\r')) buffer[--n] = 0;
        handleCommand(buffer);
    }
    // Indra closed the pipe (or quit): leave.
    _exit(0);
    return NULL;
}

void indra_np_run(void *a, void *b) {
    @autoreleasepool {
        // v490: a failure now leaves a line in nowplaying.log saying what it was doing, instead of a silent exit.
        signal(SIGPIPE, SIG_IGN);
        NSSetUncaughtExceptionHandler(&uncaughtException);
        signal(SIGSEGV, crashHandler);
        signal(SIGBUS, crashHandler);
        signal(SIGABRT, crashHandler);
        signal(SIGILL, crashHandler);
        signal(SIGTRAP, crashHandler);
        void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        if (!handle) {
            writeLine(@{@"error": @"MediaRemote could not be loaded"});
            _exit(3);
        }
        MRGetInfo = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo");
        MRGetIsPlaying = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
        MRGetClient = dlsym(handle, "MRMediaRemoteGetNowPlayingClient");
        MRClientBundle = dlsym(handle, "MRNowPlayingClientGetBundleIdentifier");
        MRClientParent = dlsym(handle, "MRNowPlayingClientGetParentAppBundleIdentifier");
        MRRegister = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications");
        MRSend = dlsym(handle, "MRMediaRemoteSendCommand");
        MRSetElapsed = dlsym(handle, "MRMediaRemoteSetElapsedTime");
        if (!MRGetInfo || !MRGetIsPlaying || !MRGetClient) {
            writeLine(@{@"error": @"MediaRemote functions are missing on this macOS"});
            _exit(4);
        }

        gQueue = dispatch_queue_create("indra.nowplaying", DISPATCH_QUEUE_SERIAL);
        if (MRRegister) MRRegister(gQueue);

        NSArray *names = @[
            @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
            @"kMRMediaRemoteNowPlayingPlaybackQueueChangedNotification",
            @"kMRNowPlayingPlaybackQueueChangedNotification",
            @"kMRPlaybackQueueContentItemsChangedNotification",
        ];
        for (NSString *name in names) {
            [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:nil
                                                          usingBlock:^(NSNotification *note) { schedule(0.12); }];
        }

        // Safety net: re-read every few seconds in case an app changes without a notification.
        gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gQueue);
        dispatch_source_set_timer(gTimer, dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), 4 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
        dispatch_source_set_event_handler(gTimer, ^{ poll(); });
        dispatch_resume(gTimer);

        pthread_t reader;
        pthread_create(&reader, NULL, readCommands, NULL);

        writeLine(@{@"ready": @YES});
        schedule(0.05);
    }
    // Park the main thread; everything else runs on gQueue and the reader thread.
    dispatch_main();
}
