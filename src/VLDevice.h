#import <Foundation/Foundation.h>
#import <stdint.h>

/// 一段 MMIO 设备。总线只负责把地址路由到这里，读写语义由设备自己决定。
@protocol VLDevice <NSObject>

- (uint64_t)baseAddress;
- (uint32_t)regionSize;

/// 读/写的是相对 baseAddress 的偏移，width 为 1/2/4。
- (uint32_t)readAtOffset:(uint32_t)offset width:(uint32_t)width;
- (void)writeAtOffset:(uint32_t)offset width:(uint32_t)width value:(uint32_t)value;

@end
