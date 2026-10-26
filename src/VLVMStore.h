#import <Foundation/Foundation.h>

#import "VLVMConfiguration.h"

/// 进程内的虚拟机列表。当前不落盘，仅供界面预览与联调。
@interface VLVMStore : NSObject

@property (nonatomic, strong, readonly) NSArray<VLVMConfiguration *> *machines;

+ (instancetype)sharedStore;

/// 追加由新建弹窗组装好的配置并返回它。
- (VLVMConfiguration *)addMachineWithConfiguration:(VLVMConfiguration *)configuration;

/// 从列表里移除一台虚拟机（只出列，不删除磁盘镜像文件）。
- (void)removeMachine:(VLVMConfiguration *)configuration;

@end
