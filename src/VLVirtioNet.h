// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 twoyears666

#import "VLVirtioMMIODevice.h"

@class VLNetStack;

/// virtio-net（legacy v1）：队列 0 收、队列 1 发，配置空间只有 MAC。
/// 网络协议本身交给 VLNetStack，这里只负责在客户机内存和以太网帧之间搬数据。
@interface VLVirtioNet : VLVirtioMMIODevice

- (instancetype)initWithBaseAddress:(uint64_t)baseAddress
						guestMemory:(VLGuestMemory *)guestMemory
					interruptNumber:(uint32_t)interruptNumber
			  interruptController:(VLInterruptController *)interruptController
							network:(VLNetStack *)network;

@property (nonatomic, strong, readonly) VLNetStack *network;

/// 把网络栈攒下的下行帧写进客户机挂上来的接收缓冲（只能在 vCPU 线程调用）。
- (void)serviceReceive;

@end
