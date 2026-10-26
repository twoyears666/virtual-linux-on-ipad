#import <Foundation/Foundation.h>

#import "VLStorageLocation.h"

/// 虚拟机存储位置登记处：默认位置 + 用户添加的外接目录，全部持久化到 NSUserDefaults。
/// 多个位置共存，各自独立；位置不可用时其下的虚拟机被界面标成「已冻结」。
@interface VLStorageManager : NSObject

@property (nonatomic, copy, readonly) NSArray<VLStorageLocation *> *locations;

+ (instancetype)sharedManager;

/// 启动时解析书签并开始访问外接目录，让已登记的位置重新可用。
- (void)restoreAccess;

/// 内置默认位置（App 文档目录/VirtualMachines），永远存在。
- (VLStorageLocation *)defaultLocation;

- (VLStorageLocation *)locationWithIdentifier:(NSString *)identifier;

/// 登记一个用户选择的位置（一般是外接磁盘上的文件夹）。
/// 失败返回 nil，error 里给出原因（书签失败或目录不可写）。
- (VLStorageLocation *)addLocationWithURL:(NSURL *)url error:(NSError **)error;

/// 从登记表移除位置，不删除目录里的任何文件；内置位置不可移除。
- (BOOL)removeLocation:(VLStorageLocation *)location;

/// 添加/移除后通知界面刷新（发送 VLStorageManagerDidChangeNotification）。
+ (NSNotificationName)didChangeNotification;

@end
