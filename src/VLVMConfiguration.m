#import "VLVMConfiguration.h"

@implementation VLVMConfiguration

+ (instancetype)sampleConfigurationWithName:(NSString *)name
								   memoryMB:(NSUInteger)memoryMB
									 diskGB:(NSUInteger)diskGB {
	VLVMConfiguration *configuration = [[VLVMConfiguration alloc] init];
	configuration.name = name;
	configuration.notes = @"";
	configuration.kernelPath = @"";
	configuration.initrdPath = @"";
	configuration.cpuCores = 4;
	configuration.memoryMB = memoryMB;
	configuration.diskGB = diskGB;
	configuration.diskReadOnly = NO;
	configuration.resolution = VLDisplayResolution1024x768;
	configuration.displayScale = VLDisplayScaleFit;
	configuration.networkMode = VLNetworkModeShared;
	configuration.macAddress = @"52:54:00:12:34:56";
	configuration.inputMode = VLInputModeDirectTouch;
	configuration.mouseCapture = YES;
	configuration.keyboardCapture = YES;
	return configuration;
}

- (instancetype)init {
	self = [super init];
	if (self) {
		_name = @"新建虚拟机";
		_notes = @"";
		_cpuCores = 4;
		_memoryMB = 2048;
		_diskGB = 16;
		_resolution = VLDisplayResolution1024x768;
		_displayScale = VLDisplayScaleFit;
		_networkMode = VLNetworkModeShared;
		_macAddress = @"52:54:00:12:34:56";
		_inputMode = VLInputModeDirectTouch;
		_mouseCapture = YES;
		_keyboardCapture = YES;
	}
	return self;
}

- (NSString *)summary {
	return [NSString stringWithFormat:@"%lu 核 · %lu MB · %lu GB",
			(unsigned long)self.cpuCores,
			(unsigned long)self.memoryMB,
			(unsigned long)self.diskGB];
}

- (NSString *)resolutionString {
	switch (self.resolution) {
		case VLDisplayResolution1280x800:
			return @"1280 × 800";
		case VLDisplayResolution1440x1080:
			return @"1440 × 1080";
		case VLDisplayResolution1920x1200:
			return @"1920 × 1200";
		case VLDisplayResolution1024x768:
		default:
			return @"1024 × 768";
	}
}

- (NSString *)displayScaleString {
	switch (self.displayScale) {
		case VLDisplayScaleFill:
			return @"填充";
		case VLDisplayScaleNative:
			return @"原始";
		case VLDisplayScaleFit:
		default:
			return @"适应";
	}
}

- (NSString *)networkModeString {
	switch (self.networkMode) {
		case VLNetworkModeBridged:
			return @"桥接";
		case VLNetworkModeNone:
			return @"无";
		case VLNetworkModeShared:
		default:
			return @"共享";
	}
}

- (NSString *)inputModeString {
	switch (self.inputMode) {
		case VLInputModePointer:
			return @"指针";
		case VLInputModeDirectTouch:
		default:
			return @"直接触控";
	}
}

@end
