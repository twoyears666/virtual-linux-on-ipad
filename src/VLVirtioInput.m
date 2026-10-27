#import "VLVirtioInput.h"

#import <string.h>

#import "VLGuestMemory.h"

#define VLInputQueueNumMax 16
#define VLInputConfigSize 128
#define VLInputMaximumCoordinate 32767

// virtio_input_config.select
#define VLInputConfigUnset 0x00
#define VLInputConfigName 0x01
#define VLInputConfigSerial 0x02
#define VLInputConfigPropBits 0x10
#define VLInputConfigEventBits 0x11
#define VLInputConfigAbsoluteInfo 0x12

// Linux input 事件类型与编码
#define VLInputEventSyn 0x00
#define VLInputEventKey 0x01
#define VLInputEventAbsolute 0x03
#define VLInputSynReport 0x00
#define VLInputButtonTouch 0x14A
#define VLInputAbsoluteX 0x00
#define VLInputAbsoluteY 0x01

typedef struct {
	uint16_t type;
	uint16_t code;
	uint32_t value;
} VLVirtioInputEvent;

typedef struct {
	uint16_t head;
	uint64_t address;
	uint32_t length;
} VLInputPendingBuffer;

static void VLInputWriteLE16(uint8_t *bytes, uint16_t value) {
	bytes[0] = (uint8_t)(value & 0xFF);
	bytes[1] = (uint8_t)((value >> 8) & 0xFF);
}

static void VLInputWriteLE32(uint8_t *bytes, uint32_t value) {
	bytes[0] = (uint8_t)(value & 0xFF);
	bytes[1] = (uint8_t)((value >> 8) & 0xFF);
	bytes[2] = (uint8_t)((value >> 16) & 0xFF);
	bytes[3] = (uint8_t)((value >> 24) & 0xFF);
}

@implementation VLVirtioInput {
	uint32_t _configSelect;
	uint32_t _configSubsel;
	BOOL _touchActive;

	// 客户机挂上来的事件缓冲区，和 App 产生、还没送出去的事件。
	NSMutableArray<NSValue *> *_pendingBuffers;
	NSMutableArray<NSValue *> *_pendingEvents;
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
		_pendingEvents = [NSMutableArray array];
	}
	return self;
}

#pragma mark - 设备描述

- (uint32_t)virtioDeviceID {
	return 18; // virtio-input
}

- (uint32_t)queueNumMax {
	return VLInputQueueNumMax;
}

- (BOOL)completesChainImmediately {
	// 缓冲区要等真有手指事件才回填，现在不能标记完成。
	return NO;
}

- (void)resetDevice {
	@synchronized (self) {
		[_pendingBuffers removeAllObjects];
		[_pendingEvents removeAllObjects];
	}
	_touchActive = NO;
	_configSelect = VLInputConfigUnset;
	_configSubsel = 0;
}

#pragma mark - 配置空间

- (uint32_t)readConfigAtOffset:(uint32_t)offset width:(uint32_t)width {
	uint8_t bytes[VLInputConfigSize];
	memset(bytes, 0, sizeof(bytes));
	[self fillConfigBytes:bytes];

	if ((uint64_t)offset + width > sizeof(bytes)) {
		return 0;
	}
	uint32_t value = 0;
	for (uint32_t index = 0; index < width; index++) {
		value |= (uint32_t)bytes[offset + index] << (8 * index);
	}
	return value;
}

- (void)writeConfigAtOffset:(uint32_t)offset width:(uint32_t)width value:(uint32_t)value {
	// 客户机先写 select，再写 subsel，然后反复读同一段配置空间。
	if (offset == 0) {
		_configSelect = value & 0xFF;
	} else if (offset == 1) {
		_configSubsel = value & 0xFF;
	}
}

- (void)fillConfigBytes:(uint8_t *)bytes {
	bytes[0] = (uint8_t)_configSelect;
	bytes[1] = (uint8_t)_configSubsel;
	uint8_t *payload = bytes + 8;
	uint32_t size = 0;

	if (_configSelect == VLInputConfigName) {
		const char *name = "VirtualLinux Touchscreen";
		size_t length = strlen(name);
		memcpy(payload, name, length);
		size = (uint32_t)length;
	} else if (_configSelect == VLInputConfigSerial) {
		const char *serial = "vl-touch-0";
		size_t length = strlen(serial);
		memcpy(payload, serial, length);
		size = (uint32_t)length;
	} else if (_configSelect == VLInputConfigPropBits) {
		// INPUT_PROP_DIRECT：直接坐标设备，libinput 会当成触摸屏。
		payload[0] = 0x01;
		size = 1;
	} else if (_configSelect == VLInputConfigEventBits) {
		if (_configSubsel == VLInputEventKey) {
			payload[VLInputButtonTouch / 8] |= (uint8_t)(1u << (VLInputButtonTouch % 8));
			size = (uint32_t)(VLInputButtonTouch / 8 + 1);
		} else if (_configSubsel == VLInputEventAbsolute) {
			payload[0] |= (uint8_t)((1u << VLInputAbsoluteX) | (1u << VLInputAbsoluteY));
			size = 1;
		} else if (_configSubsel == VLInputEventSyn) {
			size = 1;
		}
	} else if (_configSelect == VLInputConfigAbsoluteInfo) {
		if (_configSubsel == VLInputAbsoluteX || _configSubsel == VLInputAbsoluteY) {
			// min = 0，max = 32767，fuzz / flat 都为 0
			for (uint32_t index = 0; index < 4; index++) {
				payload[4 + index] =
					(uint8_t)((VLInputMaximumCoordinate >> (8 * index)) & 0xFF);
			}
			size = 24;
		}
	}

	bytes[2] = (uint8_t)size;
}

#pragma mark - 事件队列

- (uint32_t)handleDescriptorChain:(NSArray<VLVirtioBufferDescriptor *> *)chain
							 head:(uint16_t)head {
	VLVirtioBufferDescriptor *buffer = chain.firstObject;
	if (buffer == nil || !buffer.writable || buffer.length < 8) {
		return 0;
	}

	VLInputPendingBuffer pending = {head, buffer.address, buffer.length};
	@synchronized (self) {
		[_pendingBuffers addObject:[NSValue valueWithBytes:&pending
												 objCType:@encode(VLInputPendingBuffer)]];
	}
	[self flushPendingEvents];
	return 0;
}

- (void)enqueueEvents:(const VLVirtioInputEvent *)events count:(NSUInteger)count {
	// 手指事件来自主线程，这里只排队；真正写客户机内存由 vCPU 线程做。
	@synchronized (self) {
		for (NSUInteger index = 0; index < count; index++) {
			VLVirtioInputEvent event = events[index];
			[_pendingEvents addObject:[NSValue valueWithBytes:&event
													 objCType:@encode(VLVirtioInputEvent)]];
		}
	}
}

- (void)servicePendingEvents {
	[self flushPendingEvents];
}

- (void)flushPendingEvents {
	@synchronized (self) {
		while (_pendingEvents.count > 0 && _pendingBuffers.count > 0) {
			VLInputPendingBuffer buffer;
			[_pendingBuffers.firstObject getValue:&buffer];

			uint32_t capacity = buffer.length / 8;
			uint8_t *pointer =
				[self.guestMemory hostPointerForGuestAddress:buffer.address length:buffer.length];
			if (capacity == 0 || pointer == NULL) {
				[_pendingBuffers removeObjectAtIndex:0];
				continue;
			}

			uint32_t written = 0;
			while (written < capacity && _pendingEvents.count > 0) {
				VLVirtioInputEvent event;
				[_pendingEvents.firstObject getValue:&event];
				[_pendingEvents removeObjectAtIndex:0];

				uint8_t *slot = pointer + (size_t)written * 8;
				VLInputWriteLE16(slot, event.type);
				VLInputWriteLE16(slot + 2, event.code);
				VLInputWriteLE32(slot + 4, event.value);
				written++;
			}

			[_pendingBuffers removeObjectAtIndex:0];
			[self completeChainWithHead:buffer.head length:written * 8 queueIndex:0];
		}
	}
}

- (void)touchDownAtX:(uint32_t)x y:(uint32_t)y {
	if (_touchActive) {
		[self touchMoveToX:x y:y];
		return;
	}
	_touchActive = YES;

	VLVirtioInputEvent events[4] = {
		{VLInputEventAbsolute, VLInputAbsoluteX, x},
		{VLInputEventAbsolute, VLInputAbsoluteY, y},
		{VLInputEventKey, VLInputButtonTouch, 1},
		{VLInputEventSyn, VLInputSynReport, 0},
	};
	[self enqueueEvents:events count:4];
}

- (void)touchMoveToX:(uint32_t)x y:(uint32_t)y {
	if (!_touchActive) {
		return;
	}
	VLVirtioInputEvent events[3] = {
		{VLInputEventAbsolute, VLInputAbsoluteX, x},
		{VLInputEventAbsolute, VLInputAbsoluteY, y},
		{VLInputEventSyn, VLInputSynReport, 0},
	};
	[self enqueueEvents:events count:3];
}

- (void)touchUp {
	if (!_touchActive) {
		return;
	}
	_touchActive = NO;

	VLVirtioInputEvent events[2] = {
		{VLInputEventKey, VLInputButtonTouch, 0},
		{VLInputEventSyn, VLInputSynReport, 0},
	};
	[self enqueueEvents:events count:2];
}

@end
