// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 twoyears666

#import <Foundation/Foundation.h>

#import "VLDiskImage.h"

typedef NS_ENUM(NSInteger, VLDisplayResolution) {
	VLDisplayResolution1024x768 = 0,
	VLDisplayResolution1280x800,
	VLDisplayResolution1440x1080,
	VLDisplayResolution1920x1200,
	/// 跟随设备（iPad 原生分辨率，4:3）。
	VLDisplayResolutionNative,
};

typedef NS_ENUM(NSInteger, VLFrameRateLimit) {
	VLFrameRateLimit30 = 0,
	VLFrameRateLimit60,
	VLFrameRateLimitUnlimited,
};

/// 一条端口转发规则。
@interface VLPortForward : NSObject

@property (nonatomic, assign) NSUInteger hostPort;
@property (nonatomic, assign) NSUInteger guestPort;
/// TCP / UDP。
@property (nonatomic, copy) NSString *protocol;

+ (instancetype)forwardWithHostPort:(NSUInteger)hostPort
						  guestPort:(NSUInteger)guestPort
						   protocol:(NSString *)protocol;

- (NSString *)displayString;

@end

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

@property (nonatomic, copy) NSString *kernelPath;
@property (nonatomic, copy) NSString *initrdPath;
/// 安装镜像（ISO）在沙盒里的路径，为空表示未导入。
@property (nonatomic, copy) NSString *isoPath;
/// 虚拟机目录的绝对路径（<存储位置>/<UUID>），由置备阶段写入。
@property (nonatomic, copy) NSString *rootPath;
/// 所属存储位置标识，见 VLStorageManager；为空表示还没分配位置。
@property (nonatomic, copy) NSString *storageIdentifier;
/// 自动安装应答文件（preseed.cfg）路径；非 Debian 系可能为空。
@property (nonatomic, copy) NSString *preseedPath;
/// 存储目录是否还在。路径为空（还没置备）时视为可用；
/// 路径存在但目录消失（外接盘拔掉、目录被删）时虚拟机被冻结。
@property (nonatomic, readonly, getter=isStorageAvailable) BOOL storageAvailable;
/// 自定义图标路径；为空时按发行版标识显示官方图标。
@property (nonatomic, copy) NSString *iconPath;
/// 发行版标识（alpine / debian / ubuntu / arch / fedora / linux），用于列表图标。
@property (nonatomic, copy) NSString *distroIdentifier;

@property (nonatomic, assign) NSUInteger cpuCores;
@property (nonatomic, assign) NSUInteger memoryMB;
/// 多块磁盘：第一块是系统盘，其余为数据盘。
@property (nonatomic, strong) NSMutableArray<VLDiskImage *> *disks;
@property (nonatomic, assign) BOOL diskImageReady;

@property (nonatomic, assign) VLDisplayResolution resolution;
@property (nonatomic, assign) VLDisplayScale displayScale;
@property (nonatomic, assign) VLFrameRateLimit frameRateLimit;

@property (nonatomic, assign) VLNetworkMode networkMode;
@property (nonatomic, copy) NSString *macAddress;
@property (nonatomic, strong) NSMutableArray<VLPortForward *> *portForwards;

@property (nonatomic, assign) VLInputMode inputMode;
@property (nonatomic, assign) BOOL mouseCapture;
@property (nonatomic, assign) BOOL keyboardCapture;

+ (instancetype)sampleConfigurationWithName:(NSString *)name
								   memoryMB:(NSUInteger)memoryMB
									 diskGB:(NSUInteger)diskGB;

/// 追加一块盘，返回它。
- (VLDiskImage *)addDiskWithSizeGB:(NSUInteger)sizeGB;
/// 删除除系统盘外的指定盘；系统盘不可删。
- (BOOL)removeDisk:(VLDiskImage *)disk;

/// 所有磁盘容量之和（GB）。
- (NSUInteger)totalDiskGB;

/// 列表行副标题，例如「4 核 · 2048 MB · 32 GB」。
- (NSString *)summary;

- (NSString *)resolutionString;
- (NSString *)displayScaleString;
- (NSString *)networkModeString;
- (NSString *)inputModeString;
- (NSString *)frameRateLimitString;

@end
