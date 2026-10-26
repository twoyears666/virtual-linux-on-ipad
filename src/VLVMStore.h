#import <Foundation/Foundation.h>

#import "VLVMConfiguration.h"

/// 进程内的虚拟机列表。当前不落盘，仅供界面预览与联调。
@interface VLVMStore : NSObject

@property (nonatomic, strong, readonly) NSArray<VLVMConfiguration *> *machines;

+ (instancetype)sharedStore;

/// 追加由新建弹窗组装好的配置并返回它。
- (VLVMConfiguration *)addMachineWithConfiguration:(VLVMConfiguration *)configuration;

/// 删除虚拟机：整目录（ISO、图标、所有磁盘镜像）一并删除。
/// 返回 NO 表示文件删不掉，此时虚拟机仍保留在列表里。
- (BOOL)removeMachine:(VLVMConfiguration *)configuration;

@end
