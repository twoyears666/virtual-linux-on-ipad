// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 twoyears666

#import "VLVirtioConsole.h"

#import <string.h>

#import "VLGuestMemory.h"
#import "VLStartupLog.h"

/// 队列深度：hvc 驱动一次挂几十个接收缓冲，8 个太浅，容易在初始化阶段丢数据。
#define VLConsoleQueueNumMax 64
/// 报给客户机的终端尺寸（virtio_console_config.cols / rows）。
#define VLConsoleColumns 120
#define VLConsoleRows 32
#define VLConsoleConfigSize 4

/// receiveq / transmitq 的编号（virtio-console 规范固定：0 收、1 发）。
#define VLConsoleReceiveQueue 0
#define VLConsoleTransmitQueue 1

typedef struct {
	uint16_t head;
	uint64_t address;
	uint32_t length;
} VLConsolePendingBuffer;

@implementation VLVirtioConsole {
	/// 客户机挂上来的接收缓冲，要等真有输入才回填。
	NSMutableArray<NSValue *> *_pendingBuffers;
	/// 宿主产生、还没送进接收缓冲的数据。
	NSMutableData *_pendingInput;
}

- (instancetype)initWithBaseAddress:(uint64_t)baseAddress
						guestMemory:(VLGuestMemory *)guestMemory
					interruptNumber:(uint32_t)interruptNumber
			  interruptController:(VLInterruptController *)interruptController {
	self = [super initWithBaseAddress:baseAddress
						 guestMemory:guestMemory
					 interruptNumber:interruptNumber
				   interruptController:interruptController];
	if (self) {
		_pendingBuffers = [NSMutableArray array];
		_pendingInput = [NSMutableData data];
	}
	return self;
}

#pragma mark - 设备描述

- (uint32_t)virtioDeviceID {
	return 3; // virtio-console
}

- (uint32_t)virtioDeviceFeatures {
	// VIRTIO_CONSOLE_F_SIZE：告诉驱动 cols/rows。不开 F_MULTIPORT，
	// 那样驱动会走控制队列，实现和收益都不划算。
	return 1u << 0;
}

- (uint32_t)queueNumMax {
	return VLConsoleQueueNumMax;
}

- (BOOL)completesChainImmediately {
	// 接收缓冲必须留着等宿主输入，不能处理完就标完成。
	return NO;
}

- (void)resetDevice {
	@synchronized (self) {
		[_pendingBuffers removeAllObjects];
		[_pendingInput setLength:0];
	}
}

#pragma mark - 配置空间

- (uint32_t)readConfigAtOffset:(uint32_t)offset width:(uint32_t)width {
	uint8_t bytes[VLConsoleConfigSize];
	memset(bytes, 0, sizeof(bytes));
	uint16_t columns = VLConsoleColumns;
	uint16_t rows = VLConsoleRows;
	memcpy(bytes, &columns, sizeof(columns));
	memcpy(bytes + 2, &rows, sizeof(rows));

	if ((uint64_t)offset + width > sizeof(bytes)) {
		return 0;
	}
	uint32_t value = 0;
	for (uint32_t index = 0; index < width; index++) {
		value |= (uint32_t)bytes[offset + index] << (8 * index);
	}
	return value;
}

#pragma mark - 队列

- (uint32_t)handleDescriptorChain:(NSArray<VLVirtioBufferDescriptor *> *)chain
							 head:(uint16_t)head
					   queueIndex:(uint32_t)queueIndex {
	if (queueIndex == VLConsoleTransmitQueue) {
		// 客户机的 console 输出。hvc 驱动会挂两个可读描述符：数据 + 一个哨兵，
		// 只取第一个就是真正要打印的内容。
		uint32_t written = 0;
		VLVirtioBufferDescriptor *buffer = chain.firstObject;
		if (buffer != nil && !buffer.writable && buffer.length > 0) {
			uint8_t *pointer =
				[self.guestMemory hostPointerForGuestAddress:buffer.address length:buffer.length];
			if (pointer != NULL) {
				NSData *payload = [NSData dataWithBytes:pointer length:buffer.length];
				[VLStartupLog appendGuestConsoleData:payload];
				written = buffer.length;
			}
		}
		// 发送队列可以立刻回收：数据已经落到日志文件了。
		[self completeChainWithHead:head length:written queueIndex:VLConsoleTransmitQueue];
		return written;
	}

	if (queueIndex == VLConsoleReceiveQueue) {
		VLVirtioBufferDescriptor *buffer = chain.firstObject;
		if (buffer == nil || !buffer.writable || buffer.length == 0) {
			return 0;
		}
		VLConsolePendingBuffer pending = {head, buffer.address, buffer.length};
		@synchronized (self) {
			[_pendingBuffers addObject:[NSValue valueWithBytes:&pending
													 objCType:@encode(VLConsolePendingBuffer)]];
		}
		[self flushPendingInput];
	}
	return 0;
}

#pragma mark - 宿主输入

- (void)sendInputData:(NSData *)data {
	if (data.length == 0) {
		return;
	}
	@synchronized (self) {
		[_pendingInput appendData:data];
	}
	[self flushPendingInput];
}

- (void)flushPendingInput {
	@synchronized (self) {
		while (_pendingInput.length > 0 && _pendingBuffers.count > 0) {
			VLConsolePendingBuffer buffer;
			[_pendingBuffers.firstObject getValue:&buffer];

			uint8_t *pointer =
				[self.guestMemory hostPointerForGuestAddress:buffer.address length:buffer.length];
			if (pointer == NULL) {
				[_pendingBuffers removeObjectAtIndex:0];
				continue;
			}

			NSUInteger count = MIN(_pendingInput.length, (NSUInteger)buffer.length);
			memcpy(pointer, _pendingInput.bytes, count);
			[_pendingInput replaceBytesInRange:NSMakeRange(0, count) withBytes:NULL length:0];

			[_pendingBuffers removeObjectAtIndex:0];
			[self completeChainWithHead:buffer.head
								 length:(uint32_t)count
							 queueIndex:VLConsoleReceiveQueue];
		}
	}
}

@end
