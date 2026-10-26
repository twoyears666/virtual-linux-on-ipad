#import <Foundation/Foundation.h>

/// 一块虚拟磁盘。一台虚拟机可以挂多块盘，各自独立容量与镜像文件。
@interface VLDiskImage : NSObject

@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) NSUInteger sizeGB;
@property (nonatomic, assign) BOOL readOnly;
/// 镜像文件路径；为空表示还没创建。
@property (nonatomic, copy) NSString *path;

+ (instancetype)diskWithName:(NSString *)name sizeGB:(NSUInteger)sizeGB;

@end
