// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 twoyears666

#import "VLVirtioMMIODevice.h"

/// virtio-console（设备号 3）：客户机侧的 hvc0。
/// receiveq（0）放宿主发下去的数据，transmitq（1）把客户机的 console 输出取出来
/// 追加到 startup.log。相比 PL011「一个字符一次 MMIO 退出」，这里一次提交
/// 就能取走整段输出，正是 P1 想要的那笔账。
@interface VLVirtioConsole : VLVirtioMMIODevice

- (instancetype)initWithBaseAddress:(uint64_t)baseAddress
						guestMemory:(VLGuestMemory *)guestMemory
					interruptNumber:(uint32_t)interruptNumber
			  interruptController:(VLInterruptController *)interruptController;

/// 宿主往客户机 console 写数据（预留给后续的粘贴/键盘输入）。
- (void)sendInputData:(NSData *)data;

@end
