// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 twoyears666

#import <Foundation/Foundation.h>

#import "VLDevice.h"

/// QEMU pvpanic 的 MMIO 变体：两个单字节寄存器。
/// 偏移 0 读能力位（bit0 = panic 事件，bit1 = crash loaded），偏移 1 由客户机写事件。
/// 客户机内核在 panic 时会写 bit0，我们就能在宿主侧第一时间知道，
/// 不用等 rcu stall 或 watchdog 超时去猜。
@interface VLPVPanicDevice : NSObject <VLDevice>

- (instancetype)initWithBaseAddress:(uint64_t)baseAddress;

/// 客户机报告 panic 时回调（只在第一次触发）。
@property (nonatomic, copy) void (^panicHandler)(NSString *reason);

@end
