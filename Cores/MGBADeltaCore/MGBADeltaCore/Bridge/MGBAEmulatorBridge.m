// Delta frontend for the unmodified official mGBA 0.10.5 core (MPL-2.0).
// Integration follows the Delta bridging API and gal-leib/GBADeltaCore's adapter.
#import <MGBADeltaCore/MGBADeltaCore.h>
#import <DeltaCore/DeltaCore-Swift.h>
#import <GBADeltaCore/GBADeltaCore.h>
#import <TargetConditionals.h>
#if !TARGET_OS_TV
#import <CoreMotion/CoreMotion.h>
#endif
#include <mgba/core/core.h>
#include <mgba/core/blip_buf.h>
#include <mgba/core/cheats.h>
#include <mgba/core/serialize.h>
#include <mgba/gba/core.h>
#include <mgba/gba/interface.h>
#include <mgba/internal/gba/cheats.h>
#include <mgba-util/vfs.h>

@interface MGBAEmulatorBridge ()
@property (nonatomic, copy, readwrite) NSURL *gameURL;
@property (nonatomic, copy, readwrite) NSString *lastError;
#if !TARGET_OS_TV
@property (nonatomic, strong) CMMotionManager *motionManager;
#endif
@end

@implementation MGBAEmulatorBridge {
    struct mCore *_core;
    uint32_t *_pixels;
    struct mCoreCallbacks _callbacks;
    struct mRotationSource _rotation;
    struct GBALuminanceSource _light;
    BOOL _running;
    BOOL _savePending;
}
@synthesize audioRenderer = _audioRenderer;
@synthesize videoRenderer = _videoRenderer;
@synthesize saveUpdateHandler = _saveUpdateHandler;

+ (instancetype)sharedBridge {
    static MGBAEmulatorBridge *bridge;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ bridge = [self new]; });
    return bridge;
}

static void savedataUpdated(void *context) {
    // Notify after returning from mGBA, avoiding saving reentrantly inside the core.
    MGBAEmulatorBridge *bridge = (__bridge MGBAEmulatorBridge *)context;
    bridge->_savePending = YES;
}
static void sampleRotation(struct mRotationSource *source) {}
static int32_t tiltX(struct mRotationSource *source) {
#if !TARGET_OS_TV
    return (int32_t)(MGBAEmulatorBridge.sharedBridge.motionManager.accelerometerData.acceleration.x * 0x7000);
#else
    return 0;
#endif
}
static int32_t tiltY(struct mRotationSource *source) {
#if !TARGET_OS_TV
    return (int32_t)(MGBAEmulatorBridge.sharedBridge.motionManager.accelerometerData.acceleration.y * 0x7000);
#else
    return 0;
#endif
}
static int32_t gyroZ(struct mRotationSource *source) {
#if !TARGET_OS_TV
    return (int32_t)(-MGBAEmulatorBridge.sharedBridge.motionManager.gyroData.rotationRate.z * 25.0 * 256.0);
#else
    return 0;
#endif
}
static void sampleLight(struct GBALuminanceSource *source) {}
static uint8_t readLight(struct GBALuminanceSource *source) { return 0; }

- (void)startWithGameURL:(NSURL *)URL {
    [self stop];
    self.lastError = nil;
    self.gameURL = URL;
    _core = mCoreCreate(mPLATFORM_GBA);
    if (!_core) { self.lastError = @"Could not create mGBA."; return; }
    if (!_core->init(_core)) { free(_core); _core = NULL; self.lastError = @"Could not initialize mGBA."; return; }
    mCoreInitConfig(_core, NULL);
    _core->opts.useBios = false;
    _core->opts.skipBios = true;
    _core->opts.videoSync = false;
    _core->opts.audioSync = false;
    _core->opts.sampleRate = 32768;
    _core->opts.volume = 0x100;
    _core->opts.fpsTarget = 59.727500569606;
    mCoreConfigLoadDefaults(&_core->config, &_core->opts);
    _core->loadConfig(_core, &_core->config);
    _pixels = calloc(240 * 160, sizeof(uint32_t));
    if (!_pixels || !mCoreLoadFile(_core, URL.fileSystemRepresentation)) {
        [self stop]; self.lastError = @"mGBA could not load this ROM."; return;
    }
    _core->setVideoBuffer(_core, _pixels, 240);
    _core->setAudioBufferSize(_core, 2048);
    memset(&_callbacks, 0, sizeof(_callbacks));
    _callbacks.context = (__bridge void *)self;
    _callbacks.savedataUpdated = savedataUpdated;
    _core->addCoreCallbacks(_core, &_callbacks);
    _rotation = (struct mRotationSource){ .sample = sampleRotation, .readTiltX = tiltX, .readTiltY = tiltY, .readGyroZ = gyroZ };
    _light = (struct GBALuminanceSource){ .sample = sampleLight, .readLuminance = readLight };
    _core->setPeripheral(_core, mPERIPH_ROTATION, &_rotation);
    _core->setPeripheral(_core, mPERIPH_GBA_LUMINANCE, &_light);
    _core->reset(_core);
    for (int ch = 0; ch < 2; ch++) blip_set_rates(_core->getAudioChannel(_core, ch), _core->frequency(_core), 32768);
#if !TARGET_OS_TV
    self.motionManager = [CMMotionManager new];
#endif
    [self resume];
}
- (void)stop {
    [self pause];
    if (_core) { mCoreConfigDeinit(&_core->config); _core->deinit(_core); _core = NULL; }
    free(_pixels); _pixels = NULL; _savePending = NO;
}
- (void)pause {
    _running = NO;
#if !TARGET_OS_TV
    [self.motionManager stopGyroUpdates];
    [self.motionManager stopAccelerometerUpdates];
#endif
}
- (void)resume {
    _running = _core != NULL;
#if !TARGET_OS_TV
    if (_running) {
        if (self.motionManager.isGyroAvailable) [self.motionManager startGyroUpdates];
        if (self.motionManager.isAccelerometerAvailable) [self.motionManager startAccelerometerUpdates];
    }
#endif
}
- (void)runFrameAndProcessVideo:(BOOL)processVideo {
    if (!_core || !_running) return;
    _core->runFrame(_core);
    if (processVideo && self.videoRenderer.videoBuffer) {
        memcpy(self.videoRenderer.videoBuffer, _pixels, 240 * 160 * sizeof(uint32_t));
        [self.videoRenderer processFrame];
    }
    struct blip_t *left = _core->getAudioChannel(_core, 0), *right = _core->getAudioChannel(_core, 1);
    int count;
    int16_t samples[2048 * 2];
    while ((count = MIN(2048, MIN(blip_samples_avail(left), blip_samples_avail(right)))) > 0) {
        blip_read_samples(left, samples, count, 1);
        blip_read_samples(right, samples + 1, count, 1);
        [self.audioRenderer.audioBuffer writeBuffer:(uint8_t *)samples size:count * 2 * sizeof(int16_t)];
    }
    if (_savePending) { _savePending = NO; if (self.saveUpdateHandler) self.saveUpdateHandler(); }
}
- (NSTimeInterval)frameDuration { return 1.0 / 59.727500569606; }
- (void)activateInput:(NSInteger)input value:(double)value playerIndex:(NSInteger)playerIndex {
    if (_core && playerIndex == 0) _core->addKeys(_core, (uint32_t)input & 0x3ff);
}
- (void)deactivateInput:(NSInteger)input playerIndex:(NSInteger)playerIndex {
    if (_core && playerIndex == 0) _core->clearKeys(_core, (uint32_t)input & 0x3ff);
}
- (void)resetInputs { if (_core) _core->setKeys(_core, 0); }
- (void)saveGameSaveToURL:(NSURL *)URL {
    if (!_core) return;
    void *bytes = NULL;
    size_t size = _core->savedataClone(_core, &bytes);
    if (bytes && size) {
        NSError *error = nil;
        if (![[NSData dataWithBytes:bytes length:size] writeToURL:URL options:NSDataWritingAtomic error:&error]) NSLog(@"mGBA save failed: %@", error);
    }
    free(bytes);
}
- (void)loadGameSaveFromURL:(NSURL *)URL {
    if (!_core) return;
    // First use only: copy the existing VBA-M battery save; never overwrite either copy.
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:URL.path]) {
        NSURL *legacy = [URL.URLByDeletingPathExtension.URLByDeletingPathExtension URLByAppendingPathExtension:@"sav"];
        if ([fm fileExistsAtPath:legacy.path]) {
            NSError *error = nil;
            if (![fm copyItemAtURL:legacy toURL:URL error:&error]) NSLog(@"mGBA save import failed: %@", error);
        }
    }
    NSData *data = [NSData dataWithContentsOfURL:URL];
    if (data.length && !_core->savedataRestore(_core, data.bytes, data.length, true)) NSLog(@"mGBA rejected battery save: %@", URL);
}
- (void)saveSaveStateToURL:(NSURL *)URL {
    if (!_core) return;
    NSURL *temporary = [URL.URLByDeletingLastPathComponent URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
    struct VFile *file = VFileOpen(temporary.fileSystemRepresentation, O_CREAT | O_TRUNC | O_RDWR);
    if (file) {
        BOOL ok = mCoreSaveStateNamed(_core, file, SAVESTATE_SAVEDATA | SAVESTATE_RTC);
        file->close(file);
        if (ok) [[NSData dataWithContentsOfURL:temporary] writeToURL:URL options:NSDataWritingAtomic error:nil];
    }
    [NSFileManager.defaultManager removeItemAtURL:temporary error:nil];
}
- (void)loadSaveStateFromURL:(NSURL *)URL {
    if (!_core) return;
    struct VFile *file = VFileOpen(URL.fileSystemRepresentation, O_RDONLY);
    if (!file) return;
    if (!mCoreLoadStateNamed(_core, file, SAVESTATE_SAVEDATA | SAVESTATE_RTC)) NSLog(@"mGBA rejected save state: %@", URL);
    file->close(file);
    for (int ch = 0; ch < 2; ch++) blip_clear(_core->getAudioChannel(_core, ch));
}
- (BOOL)addCheatCode:(NSString *)code type:(NSString *)type {
    if (!_core) return NO;
    struct mCheatDevice *device = _core->cheatDevice(_core);
    if (!device) return NO;
    struct mCheatSet *set = device->createSet(device, "Delta");
    if (!set) return NO;
    int kind = [type isEqualToString:CheatTypeGameShark] ? GBA_CHEAT_GAMESHARK :
        ([type isEqualToString:CheatTypeActionReplay] ? GBA_CHEAT_PRO_ACTION_REPLAY : GBA_CHEAT_CODEBREAKER);
    NSString *compact = [[code componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsJoinedByString:@""];
    NSUInteger width = kind == GBA_CHEAT_CODEBREAKER ? 12 : 16;
    BOOL valid = compact.length > 0 && compact.length % width == 0;
    for (NSUInteger i = 0; valid && i < compact.length; i += width) {
        NSString *line = [NSString stringWithFormat:@"%@ %@", [compact substringWithRange:NSMakeRange(i, 8)], [compact substringWithRange:NSMakeRange(i + 8, width - 8)]];
        valid = mCheatAddLine(set, line.UTF8String, kind);
    }
    if (!valid) { mCheatSetDeinit(set); free(set); return NO; }
    mCheatAddSet(device, set); mCheatRefresh(device, set); return YES;
}
- (void)resetCheats { if (_core) mCheatDeviceClear(_core->cheatDevice(_core)); }
- (void)updateCheats {}
- (NSData *)readMemoryAtAddress:(NSInteger)address size:(NSInteger)size {
    if (!_core || address < 0 || size < 0 || size > 0x40000 || (uint64_t)address + size > UINT32_MAX) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:size];
    uint8_t *bytes = data.mutableBytes;
    for (NSInteger i = 0; i < size; i++) bytes[i] = _core->rawRead8(_core, (uint32_t)(address + i), 0);
    return data;
}
@end
