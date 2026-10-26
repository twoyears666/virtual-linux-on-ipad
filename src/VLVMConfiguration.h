#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, VLBootMode) {
	VLBootModeKernel = 0,
	VLBootModeUEFI,
};

typedef NS_ENUM(NSInteger, VLDisplayResolution) {
	VLDisplayResolution1024x768 = 0,
	VLDisplayResolution1280x800,
	VLDisplayResolution1440x1080,
	VLDisplayResolution1920x1200,
};

typedef NS_ENUM(NSInteger, VLDisplayScale) {
	VLDisplayScaleFit = 0,
	VLDisplayScaleFill,
	VLDisplayScaleNative,
};

typedef NS_ENUM(NSInteger, VLNetworkMode) {
	VLNetworkModeShared = 0,
	VLNetworkModeBridged,
	VLNetworkModeNone,
};

typedef NS_ENUM(NSInteger, VLInputMode) {
	VLInputModeDirectTouch = 0,
	VLInputModePointer,
};

/// 一台 Linux 客户机的可编辑配置。界面右侧的所有设置项都直接读写这个对象。
@interface VLVMConfiguration : NSObject

@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *notes;

@property (nonatomic, assign) VLBootMode bootMode;
@property (nonatomic, copy) NSString *kernelPath;
@property (nonatomic, copy) NSString *initrdPath;

@property (nonatomic, assign) NSUInteger cpuCores;
@property (nonatomic, assign) NSUInteger memoryMB;
@property (nonatomic, assign) NSUInteger diskGB;
@property (nonatomic, assign) BOOL diskReadOnly;

@property (nonatomic, assign) VLDisplayResolution resolution;
@property (nonatomic, assign) VLDisplayScale displayScale;

@property (nonatomic, assign) VLNetworkMode networkMode;
@property (nonatomic, copy) NSString *macAddress;

@property (nonatomic, assign) VLInputMode inputMode;
@property (nonatomic, assign) BOOL mouseCapture;
@property (nonatomic, assign) BOOL keyboardCapture;

+ (instancetype)sampleConfigurationWithName:(NSString *)name
								   memoryMB:(NSUInteger)memoryMB
									 diskGB:(NSUInteger)diskGB;

/// 列表行副标题，例如「4 核 · 2048 MB · 32 GB」。
- (NSString *)summary;

- (NSString *)bootModeString;
- (NSString *)resolutionString;
- (NSString *)displayScaleString;
- (NSString *)networkModeString;
- (NSString *)inputModeString;

@end
