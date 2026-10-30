// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 twoyears666

#import <Foundation/Foundation.h>

#import "VLDevice.h"

/// MMIO 设备总线：按物理地址找到设备并转发读写。
@interface VLDeviceBus : NSObject

- (void)addDevice:(id<VLDevice>)device;

/// 该地址是否落在某个设备区间里。只做命中判断，不触发任何设备读写（GIC 的应答类
/// 寄存器被读一次就有副作用，不能拿来试探）。
- (BOOL)containsAddress:(uint64_t)address;

/// 命中设备返回 YES 并写 value，否则返回 NO（由上层当作未知 MMIO 处理）。
- (BOOL)readAddress:(uint64_t)address width:(uint32_t)width value:(uint32_t *)value;
- (BOOL)writeAddress:(uint64_t)address width:(uint32_t)width value:(uint32_t)value;

@end
