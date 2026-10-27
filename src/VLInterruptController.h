#import <Foundation/Foundation.h>

#import "VLDevice.h"

/// 只实现 Linux 启动所需的那一小撮 GICv2 行为：
/// 分发器（0x08000000，4 KB）+ CPU 接口（0x08001000，8 KB）。
/// 中断号 0–31 走 SPI/PPI，够串口、virtio 和定时器用。
@interface VLInterruptController : NSObject <VLDevice>

- (instancetype)initWithBaseAddress:(uint64_t)baseAddress;

@property (nonatomic, readonly) uint64_t baseAddress;
@property (nonatomic, readonly) uint32_t regionSize;

/// 中断线状态变化时回调，上层据此调 hv_vcpu_set_pending_interrupt。
@property (nonatomic, copy) void (^irqLineHandler)(BOOL asserted);

/// 由设备触发（例如 virtio 写完 used ring）。
- (void)setIRQPending:(uint32_t)irq;
- (void)clearIRQPending:(uint32_t)irq;

@end
