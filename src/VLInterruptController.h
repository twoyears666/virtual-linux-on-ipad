// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 twoyears666

#import <Foundation/Foundation.h>

#import "VLDevice.h"

/// 当前线程在跑哪个 vCPU（0 起）。每个 vCPU 一个线程，GIC 靠它区分是哪个核在读
/// CPU 接口寄存器；其它设备不用关心。
uint32_t VLProcessorIndexForCurrentThread(void);
void VLSetProcessorIndexForCurrentThread(uint32_t index);

/// 只实现 Linux 启动所需的那一小撮 GICv2 行为：
/// 分发器（0x08000000，4 KB）+ CPU 接口（0x08001000，8 KB，各核共用同一窗口、
/// 寄存器按核 banking）。中断号 0–15 是 SGI，16–31 是 PPI，32 起是 SPI，
/// 够串口、virtio 和定时器用。
@interface VLInterruptController : NSObject <VLDevice>

- (instancetype)initWithBaseAddress:(uint64_t)baseAddress cpuCount:(NSUInteger)cpuCount;

@property (nonatomic, readonly) uint64_t baseAddress;
@property (nonatomic, readonly) uint32_t regionSize;
@property (nonatomic, readonly) NSUInteger cpuCount;

/// 某个核的中断线状态变化时回调，上层据此调 hv_vcpu_set_pending_interrupt。
@property (nonatomic, copy) void (^irqLineHandler)(uint32_t cpuIndex, BOOL asserted);

/// 某个核写完 GICC_EOIR（中断处理结束）时回调。虚拟定时器就靠它解除 HVF 的掩码：
/// 客户机在 EOIR 之前已经把下一次到期时间写回 CNTV_CVAL_EL0 了。
@property (nonatomic, copy) void (^interruptEndHandler)(uint32_t cpuIndex, uint32_t irq);

/// 由设备触发（例如 virtio 写完 used ring）。SGI / PPI 挂在当前线程所在的核上，
/// SPI 挂到分发器上再按 GICD_ITARGETSR 路由给目标核。
- (void)setIRQPending:(uint32_t)irq;
- (void)clearIRQPending:(uint32_t)irq;

/// 这个核当前有没有「已使能、未被屏蔽」的挂起中断。
/// WFI 陷入靠它判断能不能算完成：没有中断可投递就不该让客户机继续往下跑。
- (BOOL)hasPendingInterruptForCPU:(uint32_t)cpu;

/// 这个核当前最高优先级的待投递中断号；没有时返回 1023（spurious）。
/// 诊断用：日志里能直接看出「有挂起但一直取不走」的是哪一个中断。
- (uint32_t)highestPendingInterruptForCPU:(uint32_t)cpu;

@end
