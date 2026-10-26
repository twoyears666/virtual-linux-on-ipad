#import <Foundation/Foundation.h>

extern NSString *const VLLinuxVirtualMachineErrorDomain;

/// Linux 客户机。当前只做启动前的能力校验，vCPU / 内存映射 / virtio 引导尚未接入。
@interface VLLinuxVirtualMachine : NSObject

/// 客户机内核（Linux Image）路径，后续由选中的镜像决定。
@property (nonatomic, copy) NSString *kernelPath;

/// 初始根文件系统路径。
@property (nonatomic, copy) NSString *initrdPath;

/// 分配给客户机的内存，单位 MB。
@property (nonatomic, assign) NSUInteger memorySizeInMegabytes;

/// 启动客户机。失败时通过 error 返回具体原因。
- (BOOL)startWithError:(NSError **)error;

/// 停止客户机。
- (void)stop;

@end
