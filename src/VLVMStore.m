// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 twoyears666

#import "VLVMStore.h"

#import "VLStartupLog.h"
#import "VLStorageManager.h"

/// 配置清单固定放在默认存储位置的根目录，和磁盘镜像分开，
/// 卸载重装、换签名都不会丢。
static NSString *const VLVMStoreManifestName = @"machines.plist";

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

- (NSString *)manifestPath {
	NSString *root = VLStorageManager.sharedManager.defaultLocation.path;
	if (root.length == 0) {
		return @"";
	}
	return [root stringByAppendingPathComponent:VLVMStoreManifestName];
}

- (void)loadMachines {
	NSString *path = [self manifestPath];
	if (path.length == 0) {
		return;
	}
	NSArray *records = [NSArray arrayWithContentsOfFile:path];
	if (![records isKindOfClass:NSArray.class]) {
		return;
	}

	for (NSDictionary *record in records) {
		if (![record isKindOfClass:NSDictionary.class]) {
			continue;
		}
		VLVMConfiguration *configuration = [self configurationFromRecord:record];
		if (configuration != nil) {
			[self.mutableMachines addObject:configuration];
		}
	}
	if (self.mutableMachines.count > 0) {
		[VLStartupLog log:@"已载入 %lu 台虚拟机配置", (unsigned long)self.mutableMachines.count];
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
