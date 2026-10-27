#import "VLVirtioNet.h"

#import <string.h>

#import "VLGuestMemory.h"
#import "VLNetStack.h"
#import "VLStartupLog.h"

// 队列号：0 是客户机交上来的接收缓冲，1 是客户机要发出去的包。
#define VLVirtioNetReceiveQueue 0
#define VLVirtioNetTransmitQueue 1

// legacy v1 的 virtio_net_hdr 是 10 字节，不协商 MRG_RXBUF。
#define VLVirtioNetHeaderLength 10
#define VLVirtioNetQueueNumMax 64

// VIRTIO_NET_F_MAC：设备提供 MAC，客户机不用自己随机生成。
#define VLVirtioNetFeatureMAC (1u << 5)

typedef struct {
	uint16_t head;
	uint64_t address;
	uint32_t length;
} VLVirtioNetPendingBuffer;

@implementation VLVirtioNet {
	NSMutableArray<NSValue *> *_pendingBuffers;
}

- (instancetype)initWithBaseAddress:(uint64_t)baseAddress
						guestMemory:(VLGuestMemory *)guestMemory
					interruptNumber:(uint32_t)interruptNumber
			  interruptController:(VLInterruptController *)interruptController
							network:(VLNetStack *)network {
	self = [super initWithBaseAddress:baseAddress
						  guestMemory:guestMemory
					  interruptNumber:interruptNumber
					interruptController:interruptController];
	if (self) {
		_network = network;
		_pendingBuffers = [NSMutableArray array];
	}
	return self;
}

#pragma mark - 设备描述

- (uint32_t)virtioDeviceID {
	return 1;
}

- (uint32_t)virtioDeviceFeatures {
	return VLVirtioNetFeatureMAC;
}

- (uint32_t)queueNumMax {
	return VLVirtioNetQueueNumMax;
}

/// 收发两种队列都要自己回填 used：接收要等真有帧才完成，发送立刻完成。
- (BOOL)completesChainImmediately {
	return NO;
}

- (void)resetDevice {
	@synchronized (self) {
		[_pendingBuffers removeAllObjects];
	}
}

#pragma mark - 配置空间

- (uint32_t)readConfigAtOffset:(uint32_t)offset width:(uint32_t)width {
	uint8_t config[8] = { 0 };
	memcpy(config, self.network.macAddress.bytes, 6);
	// legacy 网卡配置在 MAC 后面还有一个 status（bit0 表示链路可用）。
	config[6] = 1;

	if (offset >= sizeof(config)) {
		return 0;
	}
	uint32_t value = 0;
	NSUInteger count = MIN((NSUInteger)width, sizeof(config) - offset);
	for (NSUInteger index = 0; index < count; index++) {
		value |= (uint32_t)config[offset + index] << (8 * index);
	}
	return value;
}

#pragma mark - 队列处理

- (uint32_t)handleDescriptorChain:(NSArray<VLVirtioBufferDescriptor *> *)chain
							 head:(uint16_t)head
					   queueIndex:(uint32_t)queueIndex {
	if (queueIndex == VLVirtioNetReceiveQueue) {
		[self acceptReceiveBuffer:chain head:head];
		return 0;
	}
	if (queueIndex == VLVirtioNetTransmitQueue) {
		[self transmitChain:chain head:head];
		return 0;
	}
	return 0;
}

- (void)acceptReceiveBuffer:(NSArray<VLVirtioBufferDescriptor *> *)chain head:(uint16_t)head {
	VLVirtioBufferDescriptor *buffer = chain.firstObject;
	if (buffer == nil || !buffer.writable || buffer.length < VLVirtioNetHeaderLength) {
		[self completeChainWithHead:head length:0 queueIndex:VLVirtioNetReceiveQueue];
		return;
	}

	VLVirtioNetPendingBuffer pending = {
		.head = head,
		.address = buffer.address,
		.length = buffer.length,
	};
	@synchronized (self) {
		[_pendingBuffers addObject:[NSValue valueWithBytes:&pending
												  objCType:@encode(VLVirtioNetPendingBuffer)]];
	}
	[self serviceReceive];
}

- (void)transmitChain:(NSArray<VLVirtioBufferDescriptor *> *)chain head:(uint16_t)head {
	NSUInteger totalLength = 0;
	for (VLVirtioBufferDescriptor *descriptor in chain) {
		totalLength += descriptor.length;
	}
	if (totalLength <= VLVirtioNetHeaderLength) {
		[self completeChainWithHead:head length:0 queueIndex:VLVirtioNetTransmitQueue];
		return;
	}

	NSMutableData *frame = [NSMutableData dataWithCapacity:totalLength];
	NSUInteger skip = VLVirtioNetHeaderLength;
	for (VLVirtioBufferDescriptor *descriptor in chain) {
		const uint8_t *source =
			[self.guestMemory hostPointerForGuestAddress:descriptor.address
												  length:descriptor.length];
		if (source == NULL) {
			[self completeChainWithHead:head length:0 queueIndex:VLVirtioNetTransmitQueue];
			return;
		}
		NSUInteger offset = 0;
		if (skip > 0) {
			offset = MIN(skip, (NSUInteger)descriptor.length);
			skip -= offset;
		}
		if (offset < descriptor.length) {
			[frame appendBytes:source + offset length:descriptor.length - offset];
		}
	}

	if (frame.length > 0) {
		[self.network handleGuestFrame:frame];
	}
	[self completeChainWithHead:head length:(uint32_t)totalLength queueIndex:VLVirtioNetTransmitQueue];
}

#pragma mark - 下行

- (void)serviceReceive {
	@synchronized (self) {
		while (_pendingBuffers.count > 0 && self.network.hasOutboundFrames) {
			NSData *frame = [self.network dequeueOutboundFrame];
			if (frame == nil) {
				break;
			}

			VLVirtioNetPendingBuffer pending;
			[_pendingBuffers.firstObject getValue:&pending size:sizeof(pending)];
			[_pendingBuffers removeObjectAtIndex:0];

			NSUInteger required = VLVirtioNetHeaderLength + frame.length;
			uint8_t *destination =
				[self.guestMemory hostPointerForGuestAddress:pending.address
													  length:pending.length];
			if (destination == NULL || pending.length < required) {
				// 缓冲太小或地址无效，这一帧只能丢掉，但不能把缓冲占死。
				[self completeChainWithHead:pending.head length:0 queueIndex:VLVirtioNetReceiveQueue];
				continue;
			}
			memset(destination, 0, VLVirtioNetHeaderLength);
			memcpy(destination + VLVirtioNetHeaderLength, frame.bytes, frame.length);
			[self completeChainWithHead:pending.head
								 length:(uint32_t)required
							 queueIndex:VLVirtioNetReceiveQueue];
		}
	}
}

@end
