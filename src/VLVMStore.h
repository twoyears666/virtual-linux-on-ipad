#import <Foundation/Foundation.h>

#import "VLVMConfiguration.h"

/// 进程内的虚拟机列表。当前不落盘，仅供界面预览与联调。
@interface VLVMStore : NSObject

@property (nonatomic, strong, readonly) NSArray<VLVMConfiguration *> *machines;

+ (instancetype)sharedStore;

/// 追加一台示例配置并返回它。
- (VLVMConfiguration *)addMachine;

@end
