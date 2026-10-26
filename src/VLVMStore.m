#import "VLVMStore.h"

@interface VLVMStore ()

@property (nonatomic, strong) NSMutableArray<VLVMConfiguration *> *mutableMachines;

@end

@implementation VLVMStore

+ (instancetype)sharedStore {
	static VLVMStore *store = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		store = [[VLVMStore alloc] init];
	});
	return store;
}

- (instancetype)init {
	self = [super init];
	if (self) {
		_mutableMachines = [NSMutableArray array];

		VLVMConfiguration *alpine =
			[VLVMConfiguration sampleConfigurationWithName:@"Alpine Linux" memoryMB:2048 diskGB:16];
		alpine.cpuCores = 4;
		alpine.resolution = VLDisplayResolution1024x768;
		[_mutableMachines addObject:alpine];

		VLVMConfiguration *debian =
			[VLVMConfiguration sampleConfigurationWithName:@"Debian 12" memoryMB:4096 diskGB:32];
		debian.cpuCores = 6;
		debian.resolution = VLDisplayResolution1280x800;
		debian.networkMode = VLNetworkModeBridged;
		[_mutableMachines addObject:debian];
	}
	return self;
}

- (NSArray<VLVMConfiguration *> *)machines {
	return [self.mutableMachines copy];
}

- (VLVMConfiguration *)addMachine {
	VLVMConfiguration *machine =
		[VLVMConfiguration sampleConfigurationWithName:[NSString stringWithFormat:@"虚拟机 %lu",
														(unsigned long)self.mutableMachines.count + 1]
											  memoryMB:2048
												diskGB:16];
	[self.mutableMachines addObject:machine];
	return machine;
}

@end
