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
		alpine.distroIdentifier = @"alpine";
		alpine.resolution = VLDisplayResolution1024x768;
		[_mutableMachines addObject:alpine];

		VLVMConfiguration *debian =
			[VLVMConfiguration sampleConfigurationWithName:@"Debian 12" memoryMB:4096 diskGB:32];
		debian.cpuCores = 6;
		debian.distroIdentifier = @"debian";
		debian.resolution = VLDisplayResolution1280x800;
		debian.networkMode = VLNetworkModeBridged;
		[_mutableMachines addObject:debian];
	}
	return self;
}

- (NSArray<VLVMConfiguration *> *)machines {
	return [self.mutableMachines copy];
}

- (VLVMConfiguration *)addMachineWithConfiguration:(VLVMConfiguration *)configuration {
	[self.mutableMachines addObject:configuration];
	return configuration;
}

- (void)removeMachine:(VLVMConfiguration *)configuration {
	if (configuration == nil) {
		return;
	}
	// 只从列表移除；磁盘镜像留在沙盒里，避免误删不可恢复的数据。
	[self.mutableMachines removeObject:configuration];
}

@end
