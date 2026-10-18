#import <Foundation/Foundation.h>
#import <DeltaCore/DeltaCore.h>
NS_ASSUME_NONNULL_BEGIN
@interface MGBAEmulatorBridge : NSObject <DLTAEmulatorBridging>
@property (class, nonatomic, readonly) MGBAEmulatorBridge *sharedBridge;
@property (nonatomic, copy, readonly, nullable) NSString *lastError;
@end
NS_ASSUME_NONNULL_END
