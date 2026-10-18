#import "PlayEmulatorBridge.h"
#import <DeltaCore/DeltaCore.h>
#import <DeltaCore/DeltaCore-Swift.h>
#import <mach/mach.h>
#import <libkern/OSCacheControl.h>
#import "DeltaPlayBackend.h"
#include <array>
#include <exception>

@interface PlayEmulatorBridge () {
    std::array<std::array<double, 24>, 2> _inputs;
    BOOL _started;
    BOOL _booted;
}
@property(nonatomic, copy, readwrite, nullable) NSURL *gameURL;
@property(nonatomic, copy, readwrite, nullable) NSString *lastError;
@property(nonatomic, strong) NSURL *storageURL;
@end

static void PrepareVideo(void *context) {
    PlayEmulatorBridge *bridge = (__bridge PlayEmulatorBridge *)context;
    [bridge.videoRenderer prepare];
}
static void PresentVideo(void *context) {
    PlayEmulatorBridge *bridge = (__bridge PlayEmulatorBridge *)context;
    [bridge.videoRenderer processFrame];
}
static void WriteAudio(void *context, const int16_t *samples, unsigned count) {
    PlayEmulatorBridge *bridge = (__bridge PlayEmulatorBridge *)context;
    [bridge.audioRenderer.audioBuffer writeBuffer:(void *)samples size:count * sizeof(int16_t)];
}

@implementation PlayEmulatorBridge
@synthesize audioRenderer = _audioRenderer, videoRenderer = _videoRenderer, saveUpdateHandler = _saveUpdateHandler;
+ (instancetype)sharedBridge {
    static PlayEmulatorBridge *bridge;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ bridge = [PlayEmulatorBridge new]; bridge.isJITEnabled = YES; });
    return bridge;
}
+ (NSString *)jitUnavailableReason {
    char reason[512] = {};
    if(delta_play_probe_jit(reason, sizeof(reason))) return nil;
    return [NSString stringWithUTF8String:reason];
}
+ (BOOL)canExecuteJIT { return self.jitUnavailableReason == nil; }
- (AVAudioFormat *)preferredAudioFormat {
    return [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16 sampleRate:44100 channels:2 interleaved:YES];
}
- (NSTimeInterval)frameDuration { return 1.0 / 60.0; }
- (BOOL)supportsJIT { return YES; }
- (BOOL)isJITActive { return _started && _booted; }
- (void)startWithGameURL:(NSURL *)url {
    @synchronized(self) {
        self.lastError = nil;
        if(!self.isJITEnabled) {
            self.lastError = @"The JIT preference is disabled. Play! has no interpreter fallback.";
            return;
        }
        NSString *permissionError = PlayEmulatorBridge.jitUnavailableReason;
        if(permissionError) {
            self.lastError = [@"tvOS denied Play!'s executable memory: " stringByAppendingString:permissionError];
            return;
        }
        // Keep cards outside the ROM tree so their files never become library entries.
#if TARGET_OS_TV
        NSURL *support = [[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
#else
        NSURL *support = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
        if(!support) support = [[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
#endif
        self.storageURL = [[support URLByAppendingPathComponent:@"PlayDeltaCore"] URLByAppendingPathComponent:url.lastPathComponent];
        NSError *dirError = nil;
        [[NSFileManager defaultManager] createDirectoryAtURL:self.storageURL withIntermediateDirectories:YES attributes:nil error:&dirError];
        if(dirError) {
            NSLog(@"[PlayEmulatorBridge] Failed to create storageURL at %@: %@", self.storageURL, dirError);
        }
        DeltaPlayCallbacks cb = { PrepareVideo, PresentVideo, WriteAudio, (__bridge void *)self };
        _started = delta_play_start(url.fileSystemRepresentation, self.storageURL.fileSystemRepresentation, cb);
        if(_started) self.gameURL = url;
        else self.lastError = [NSString stringWithUTF8String:delta_play_error()];
        _booted = NO;
        [self resetInputs];
    }
}
- (void)stop {
    @synchronized(self) {
        if(_started) delta_play_stop();
        _started = NO; _booted = NO; self.gameURL = nil;
    }
}
- (void)pause { @synchronized(self) { if(_started) delta_play_pause(); } }
- (void)resume {
    @synchronized(self) {
        if(!_started) return;
        try { delta_play_resume(); _booted = YES; }
        catch(const std::exception &error) {
            self.lastError = [NSString stringWithUTF8String:error.what()];
            delta_play_stop(); _started = NO; self.gameURL = nil;
        }
    }
}
- (void)runFrameAndProcessVideo:(BOOL)processVideo {
    // Play! owns its CPU/GS threads and frame limiter. Delta owns pause/lifecycle/audio.
    // Start after Delta has restored the game's memory-card archive.
    if(!_booted) [self resume];
}
- (void)activateInput:(NSInteger)input value:(double)value playerIndex:(NSInteger)player {
    @synchronized(self) {
        if(!_started || player < 0 || player >= 2 || input < 0 || input >= 24) return;
        _inputs[player][input] = value;
        static const unsigned buttons[] = {4,5,6,7,13,12,10,11,14,15,16,17,18,19,9,8};
        if(input < 16) delta_play_input((unsigned)player, buttons[input], value);
        else {
            static const unsigned axes[] = {1,1,0,0,3,3,2,2};
            unsigned pair = ((unsigned)input - 16) / 2 * 2 + 16;
            delta_play_input((unsigned)player, axes[input - 16], _inputs[player][pair + 1] - _inputs[player][pair]);
        }
    }
}
- (void)deactivateInput:(NSInteger)input playerIndex:(NSInteger)player { [self activateInput:input value:0 playerIndex:player]; }
- (void)resetInputs {
    @synchronized(self) {
        _inputs = {};
        if(_started) for(unsigned p=0;p<2;p++) for(unsigned i=0;i<20;i++) delta_play_input(p,i,0);
    }
}
- (void)saveSaveStateToURL:(NSURL *)url {
    @synchronized(self) {
        self.lastError = nil;
        if(!_started) { self.lastError = @"Play! is not running."; return; }
        NSURL *temporary = [url.URLByDeletingLastPathComponent URLByAppendingPathComponent:[NSString stringWithFormat:@".%@.ps2state", NSUUID.UUID.UUIDString]];
        if(delta_play_state(temporary.fileSystemRepresentation, false)) {
            NSError *error;
            NSData *state = [NSData dataWithContentsOfURL:temporary options:NSDataReadingMappedIfSafe error:&error];
            if(!state || ![state writeToURL:url options:NSDataWritingAtomic error:&error]) self.lastError = error.localizedDescription;
        } else self.lastError = [NSString stringWithUTF8String:delta_play_error()];
        [NSFileManager.defaultManager removeItemAtURL:temporary error:nil];
    }
}
- (void)loadSaveStateFromURL:(NSURL *)url {
    @synchronized(self) {
        self.lastError = nil;
        if(!_started || !delta_play_state(url.fileSystemRepresentation, true)) self.lastError = @"Play! could not load this save state.";
    }
}
- (void)saveGameSaveToURL:(NSURL *)url {
    @synchronized(self) {
        if(!_started) return;
        BOOL running = delta_play_running();
        delta_play_pause();
        NSMutableDictionary *files = [NSMutableDictionary dictionary];
        NSFileManager *fm = NSFileManager.defaultManager;
        for(NSString *card in @[@"mc0", @"mc1"]) {
            NSURL *root = [self.storageURL URLByAppendingPathComponent:card];
            for(NSURL *file in [fm enumeratorAtURL:root includingPropertiesForKeys:@[NSURLIsRegularFileKey] options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil]) {
                NSNumber *regular; [file getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
                if(!regular.boolValue) continue;
                NSData *data = [NSData dataWithContentsOfURL:file];
                if(data) files[[file.path substringFromIndex:self.storageURL.path.length + 1]] = data;
            }
        }
        NSData *archive = [NSPropertyListSerialization dataWithPropertyList:files format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
        if(archive) [archive writeToURL:url options:NSDataWritingAtomic error:nil];
        if(running) delta_play_resume();
    }
}
- (void)loadGameSaveFromURL:(NSURL *)url {
    @synchronized(self) {
        if(!_started || _booted) return;
        NSData *data = [NSData dataWithContentsOfURL:url];
        if(!data) return;
        id archive = [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:nil];
        if(![archive isKindOfClass:NSDictionary.class]) return;
        for(id key in archive) {
            if(![key isKindOfClass:NSString.class] || ![archive[key] isKindOfClass:NSData.class]) continue;
            NSArray *parts = [key pathComponents];
            if(parts.count < 2 || ![@[@"mc0",@"mc1"] containsObject:parts.firstObject] || [parts containsObject:@".."] || [key isAbsolutePath]) continue;
            NSURL *file = [self.storageURL URLByAppendingPathComponent:key];
            [NSFileManager.defaultManager createDirectoryAtURL:file.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
            [archive[key] writeToURL:file options:NSDataWritingAtomic error:nil];
        }
    }
}
- (BOOL)addCheatCode:(NSString *)code type:(NSString *)type { return NO; }
- (void)resetCheats {}
- (void)updateCheats {}
@end
