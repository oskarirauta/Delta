#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
@protocol DLTAEmulatorBridging;
NS_ASSUME_NONNULL_BEGIN
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
@interface PlayEmulatorBridge : NSObject <DLTAEmulatorBridging>
#pragma clang diagnostic pop
@property(class, nonatomic, readonly) PlayEmulatorBridge *sharedBridge;
@property(nonatomic, copy, readonly, nullable) NSURL *gameURL;
@property(nonatomic, readonly) AVAudioFormat *preferredAudioFormat;
@property(nonatomic, readonly) BOOL supportsJIT;
@property(nonatomic, readonly, getter=isJITActive) BOOL jitActive;
@property(nonatomic, assign) BOOL isJITEnabled;
@property(nonatomic, readonly, nullable) NSString *lastError;
// Preflight the actual allocator and patch protections without executing a probe.
+ (BOOL)canExecuteJIT;
@property(class, nonatomic, readonly, nullable) NSString *jitUnavailableReason;
@end
NS_ASSUME_NONNULL_END
