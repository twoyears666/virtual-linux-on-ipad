#import "VLVMStore.h"

#import "VLStartupLog.h"

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

- (BOOL)removeMachine:(VLVMConfiguration *)configuration {
	if (configuration == nil) {
		return NO;
	}

	// 真删磁盘文件：整目录带走 ISO、图标和所有稀疏镜像。
	NSString *rootPath = configuration.rootPath;
	if (rootPath.length == 0 && configuration.isoPath.length > 0) {
		// 旧数据没有记录 rootPath，从 install.iso 反推 <位置>/<UUID> 这层。
		NSURL *isoDirectory = [NSURL fileURLWithPath:configuration.isoPath].URLByDeletingLastPathComponent;
		if ([isoDirectory.URLByDeletingLastPathComponent.lastPathComponent isEqualToString:@"VirtualMachines"]) {
			rootPath = isoDirectory.path;
		}
	}

	NSFileManager *fileManager = NSFileManager.defaultManager;
	if (rootPath.length > 0 && [fileManager fileExistsAtPath:rootPath]) {
		NSError *error = nil;
		if (![fileManager removeItemAtPath:rootPath error:&error]) {
			[VLStartupLog log:@"删除虚拟机目录失败：%@（%@）", rootPath, error.localizedDescription];
			return NO;
		}
		[VLStartupLog log:@"已删除虚拟机目录：%@", rootPath];
	}

	[self.mutableMachines removeObject:configuration];
	return YES;
}

@end
