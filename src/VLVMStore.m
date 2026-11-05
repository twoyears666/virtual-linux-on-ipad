// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 twoyears666

#import "VLVMStore.h"

#import "VLStartupLog.h"
#import "VLStorageManager.h"

/// 配置清单固定放在各个存储位置的根目录，和磁盘镜像分开，
/// 卸载重装、换签名都不会丢。
static NSString *const VLVMStoreManifestName = @"machines.plist";
/// 旧版默认位置是「Documents/VirtualMachines」，新版换到 /var/mobile/Media 后
/// 必须继续把老清单读回来，否则用户会以为更新完虚拟机全没了。
static NSString *const VLVMStoreLegacyFolderName = @"VirtualMachines";

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
		[self loadMachines];
	}
	return self;
}

#pragma mark - 持久化

/// 写入用的清单路径：当前默认位置的根目录。
- (NSString *)manifestPath {
	NSString *root = VLStorageManager.sharedManager.defaultLocation.path;
	if (root.length == 0) {
		return @"";
	}
	return [root stringByAppendingPathComponent:VLVMStoreManifestName];
}

/// 读取时把所有可能放清单的地方都走一遍：默认位置、每个登记过的外接目录、
/// 以及旧版写在 App 沙盒里的 Documents/VirtualMachines。只读默认位置的话，
/// 换存储位置或升级后清单搬家，列表就空了。
- (NSArray<NSString *> *)manifestPathsForLoading {
	NSMutableArray<NSString *> *paths = [NSMutableArray array];

	NSString *defaultPath = [self manifestPath];
	if (defaultPath.length > 0) {
		[paths addObject:defaultPath];
	}

	for (VLStorageLocation *location in VLStorageManager.sharedManager.locations) {
		if (location.path.length == 0) {
			continue;
		}
		NSString *path = [location.path stringByAppendingPathComponent:VLVMStoreManifestName];
		if (![paths containsObject:path]) {
			[paths addObject:path];
		}
	}

	NSString *documentsRoot =
		[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
	if (documentsRoot.length > 0) {
		NSString *legacyPath = [[documentsRoot stringByAppendingPathComponent:VLVMStoreLegacyFolderName]
			stringByAppendingPathComponent:VLVMStoreManifestName];
		if (![paths containsObject:legacyPath]) {
			[paths addObject:legacyPath];
		}
	}

	return paths;
}

- (void)loadMachines {
	// 同一个虚拟机可能同时出现在两份清单里（旧位置一份、新位置一份），
	// 按存放目录去重，避免列表里出现两份同名虚拟机。
	NSMutableSet<NSString *> *seen = [NSMutableSet set];
	NSMutableArray<NSString *> *loadedPaths = [NSMutableArray array];

	for (NSString *path in [self manifestPathsForLoading]) {
		NSArray *records = [NSArray arrayWithContentsOfFile:path];
		if (![records isKindOfClass:NSArray.class] || records.count == 0) {
			continue;
		}

		NSUInteger added = 0;
		for (NSDictionary *record in records) {
			if (![record isKindOfClass:NSDictionary.class]) {
				continue;
			}
			VLVMConfiguration *configuration = [self configurationFromRecord:record];
			if (configuration == nil) {
				continue;
			}
			NSString *key = configuration.rootPath.length > 0
				? configuration.rootPath
				: [NSString stringWithFormat:@"%@|%@", configuration.name, configuration.kernelPath];
			if ([seen containsObject:key]) {
				continue;
			}
			[seen addObject:key];
			[self.mutableMachines addObject:configuration];
			added++;
		}
		if (added > 0) {
			[loadedPaths addObject:path];
		}
	}

	if (self.mutableMachines.count > 0) {
		[VLStartupLog log:@"已载入 %lu 台虚拟机配置（来自 %lu 份清单）",
		 (unsigned long)self.mutableMachines.count, (unsigned long)loadedPaths.count];
	}

	// 清单是从别处读回来的（旧版 Documents、外接盘），当前默认位置还没有清单：
	// 立刻补写一份，下次启动只读默认位置也不会丢。
	NSString *defaultPath = [self manifestPath];
	if (loadedPaths.count > 0 && defaultPath.length > 0 &&
		![NSFileManager.defaultManager fileExistsAtPath:defaultPath]) {
		[self saveMachines];
		[VLStartupLog log:@"已把虚拟机清单合并写入默认位置：%@", defaultPath];
	}
}

- (void)saveMachines {
	NSString *path = [self manifestPath];
	if (path.length == 0) {
		return;
	}
	NSMutableArray *records = [NSMutableArray array];
	for (VLVMConfiguration *configuration in self.mutableMachines) {
		[records addObject:[self recordForConfiguration:configuration]];
	}
	if (![records writeToFile:path atomically:YES]) {
		[VLStartupLog log:@"保存虚拟机清单失败：%@", path];
	}
}

- (NSDictionary *)recordForConfiguration:(VLVMConfiguration *)configuration {
	NSMutableArray *disks = [NSMutableArray array];
	for (VLDiskImage *disk in configuration.disks) {
		[disks addObject:@{
			@"identifier": disk.identifier ?: @"",
			@"name": disk.name ?: @"",
			@"sizeGB": @(disk.sizeGB),
			@"readOnly": @(disk.readOnly),
			@"path": disk.path ?: @"",
		}];
	}

	NSMutableArray *forwards = [NSMutableArray array];
	for (VLPortForward *forward in configuration.portForwards) {
		[forwards addObject:@{
			@"hostPort": @(forward.hostPort),
			@"guestPort": @(forward.guestPort),
			@"protocol": forward.protocol ?: @"TCP",
		}];
	}

	return @{
		@"name": configuration.name ?: @"",
		@"notes": configuration.notes ?: @"",
		@"kernelPath": configuration.kernelPath ?: @"",
		@"initrdPath": configuration.initrdPath ?: @"",
		@"isoPath": configuration.isoPath ?: @"",
		@"rootPath": configuration.rootPath ?: @"",
		@"storageIdentifier": configuration.storageIdentifier ?: @"",
		@"preseedPath": configuration.preseedPath ?: @"",
		@"iconPath": configuration.iconPath ?: @"",
		@"distroIdentifier": configuration.distroIdentifier ?: @"linux",
		@"cpuCores": @(configuration.cpuCores),
		@"memoryMB": @(configuration.memoryMB),
		@"diskImageReady": @(configuration.diskImageReady),
		@"resolution": @(configuration.resolution),
		@"displayScale": @(configuration.displayScale),
		@"frameRateLimit": @(configuration.frameRateLimit),
		@"networkMode": @(configuration.networkMode),
		@"macAddress": configuration.macAddress ?: @"",
		@"inputMode": @(configuration.inputMode),
		@"mouseCapture": @(configuration.mouseCapture),
		@"keyboardCapture": @(configuration.keyboardCapture),
		@"disks": disks,
		@"portForwards": forwards,
	};
}

- (VLVMConfiguration *)configurationFromRecord:(NSDictionary *)record {
	VLVMConfiguration *configuration = [[VLVMConfiguration alloc] init];
	configuration.name = record[@"name"] ?: @"虚拟机";
	configuration.notes = record[@"notes"] ?: @"";
	configuration.kernelPath = record[@"kernelPath"] ?: @"";
	configuration.initrdPath = record[@"initrdPath"] ?: @"";
	configuration.isoPath = record[@"isoPath"] ?: @"";
	configuration.rootPath = record[@"rootPath"] ?: @"";
	configuration.storageIdentifier = record[@"storageIdentifier"] ?: @"";
	configuration.preseedPath = record[@"preseedPath"] ?: @"";
	configuration.iconPath = record[@"iconPath"] ?: @"";
	configuration.distroIdentifier = record[@"distroIdentifier"] ?: @"linux";
	configuration.cpuCores = [record[@"cpuCores"] unsignedIntegerValue];
	configuration.memoryMB = [record[@"memoryMB"] unsignedIntegerValue];
	configuration.diskImageReady = [record[@"diskImageReady"] boolValue];
	configuration.resolution = (VLDisplayResolution)[record[@"resolution"] integerValue];
	configuration.displayScale = (VLDisplayScale)[record[@"displayScale"] integerValue];
	configuration.frameRateLimit = (VLFrameRateLimit)[record[@"frameRateLimit"] integerValue];
	configuration.networkMode = (VLNetworkMode)[record[@"networkMode"] integerValue];
	configuration.macAddress = record[@"macAddress"] ?: @"";
	configuration.inputMode = (VLInputMode)[record[@"inputMode"] integerValue];
	configuration.mouseCapture = [record[@"mouseCapture"] boolValue];
	configuration.keyboardCapture = [record[@"keyboardCapture"] boolValue];

	NSArray *disks = record[@"disks"];
	if ([disks isKindOfClass:NSArray.class] && disks.count > 0) {
		NSMutableArray<VLDiskImage *> *images = [NSMutableArray array];
		for (NSDictionary *item in disks) {
			if (![item isKindOfClass:NSDictionary.class]) {
				continue;
			}
			VLDiskImage *disk = [VLDiskImage diskWithName:item[@"name"] ?: @"磁盘"
												   sizeGB:[item[@"sizeGB"] unsignedIntegerValue]];
			disk.identifier = item[@"identifier"] ?: @"";
			disk.readOnly = [item[@"readOnly"] boolValue];
			disk.path = item[@"path"] ?: @"";
			[images addObject:disk];
		}
		if (images.count > 0) {
			configuration.disks = images;
		}
	}

	NSArray *forwards = record[@"portForwards"];
	if ([forwards isKindOfClass:NSArray.class] && forwards.count > 0) {
		NSMutableArray<VLPortForward *> *rules = [NSMutableArray array];
		for (NSDictionary *item in forwards) {
			if (![item isKindOfClass:NSDictionary.class]) {
				continue;
			}
			[rules addObject:[VLPortForward forwardWithHostPort:[item[@"hostPort"] unsignedIntegerValue]
													  guestPort:[item[@"guestPort"] unsignedIntegerValue]
													   protocol:item[@"protocol"]]];
		}
		configuration.portForwards = rules;
	}

	return configuration;
}

#pragma mark - 增删

- (NSArray<VLVMConfiguration *> *)machines {
	return [self.mutableMachines copy];
}

- (VLVMConfiguration *)addMachineWithConfiguration:(VLVMConfiguration *)configuration {
	[self.mutableMachines addObject:configuration];
	[self saveMachines];
	return configuration;
}

- (void)save {
	[self saveMachines];
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
	[self saveMachines];
	return YES;
}

@end
