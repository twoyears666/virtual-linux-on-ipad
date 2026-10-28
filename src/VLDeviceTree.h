#import <Foundation/Foundation.h>
#import <stdint.h>

/// 自己拼 FDT（flattened device tree）：把内存、CPU、GIC、定时器、串口和 virtio-mmio 声明给客户机内核。
/// 不依赖任何第三方 DTB，布局完全按本项目的 MMIO 规划来。
@interface VLDeviceTree : NSObject

/// 生成一份 arm64 Linux 可用的设备树 blob。cpuCount 决定 /cpus 下声明几个核。
/// 只有 hasBlockDisk / hasISODisc 为真时才声明对应的 virtio-mmio 节点——声明了却没有设备，
/// 内核一探测就会撞上未实现的 MMIO 地址，整台机直接停。
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
							 netBase:(uint64_t)netBase
						hasBlockDisk:(BOOL)hasBlockDisk
						   hasISODisc:(BOOL)hasISODisc;

@end
