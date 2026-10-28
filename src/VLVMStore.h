#import <Foundation/Foundation.h>

#import "VLVMConfiguration.h"

/// 虚拟机列表：清单持久化到默认存储位置的 machines.plist（/var/mobile/Media/VirtualMachines），
/// 卸载重装、换签名都不会丢。
@interface VLVMStore : NSObject

@property (nonatomic, strong, readonly) NSArray<VLVMConfiguration *> *machines;

+ (instancetype)sharedStore;

/// 追加由新建弹窗组装好的配置并返回它。
- (VLVMConfiguration *)addMachineWithConfiguration:(VLVMConfiguration *)configuration;

/// 把当前列表写回 machines.plist；界面里改过设置后调用。
- (void)save;

/// 删除虚拟机：整目录（ISO、图标、所有磁盘镜像）一并删除。
/// 返回 NO 表示文件删不掉，此时虚拟机仍保留在列表里。
- (BOOL)removeMachine:(VLVMConfiguration *)configuration;

@end
