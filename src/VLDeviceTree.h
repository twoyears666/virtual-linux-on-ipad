#import <Foundation/Foundation.h>
#import <stdint.h>

/// 自己拼 FDT（flattened device tree）：把内存、CPU、GIC、定时器、串口和 virtio-mmio 声明给客户机内核。
/// 不依赖任何第三方 DTB，布局完全按本项目的 MMIO 规划来。
@interface VLDeviceTree : NSObject

/// 生成一份 arm64 Linux 可用的设备树 blob。cpuCount 决定 /cpus 下声明几个核，
/// 以及 GIC 的 CPU 接口窗口有多大。
+ (NSData *)deviceTreeWithMemoryBase:(uint64_t)memoryBase
						  memorySize:(uint64_t)memorySize
					   bootArguments:(NSString *)bootArguments
						 initrdStart:(uint64_t)initrdStart
						   initrdEnd:(uint64_t)initrdEnd
						   cpuCount:(NSUInteger)cpuCount
							uartBase:(uint64_t)uartBase
							 gicBase:(uint64_t)gicBase
							 gpuBase:(uint64_t)gpuBase
						   blockBase:(uint64_t)blockBase
							 isoBase:(uint64_t)isoBase
						   inputBase:(uint64_t)inputBase
							 netBase:(uint64_t)netBase;

@end
