#import "VLVirtioMMIODevice.h"

#import <string.h>

#import "VLGuestMemory.h"
#import "VLInterruptController.h"
#import "VLStartupLog.h"

// virtio-mmio legacy v1 寄存器偏移
#define VLVirtioRegisterMagic 0x000
#define VLVirtioRegisterVersion 0x004
#define VLVirtioRegisterDeviceID 0x008
#define VLVirtioRegisterVendorID 0x00C
#define VLVirtioRegisterDeviceFeatures 0x010
#define VLVirtioRegisterDeviceFeaturesSel 0x014
#define VLVirtioRegisterDriverFeatures 0x020
#define VLVirtioRegisterDriverFeaturesSel 0x024
#define VLVirtioRegisterQueueSel 0x030
#define VLVirtioRegisterQueueNumMax 0x034
#define VLVirtioRegisterQueueNum 0x038
#define VLVirtioRegisterQueueAlign 0x03C
#define VLVirtioRegisterQueuePFN 0x040
#define VLVirtioRegisterQueueNotify 0x050
#define VLVirtioRegisterInterruptStatus 0x060
#define VLVirtioRegisterInterruptACK 0x064
#define VLVirtioRegisterStatus 0x070
#define VLVirtioConfigOffset 0x100

#define VLVirtioMaximumQueues 2
#define VLVirtioMaximumChainLength 16
#define VLVirtioMaximumNotificationsPerRun 32

typedef struct {
	uint32_t num;
	uint32_t align;
	uint32_t pfn;
	uint32_t lastAvailable;
} VLVirtioQueueState;

static uint64_t VLAlignUp64(uint64_t value, uint64_t alignment) {
	return (value + alignment - 1) & ~(alignment - 1);
}

static uint16_t VLReadLE16(const uint8_t *bytes) {
	return (uint16_t)((uint16_t)bytes[0] | ((uint16_t)bytes[1] << 8));
}

static uint32_t VLReadLE32(const uint8_t *bytes) {
	return (uint32_t)bytes[0] |
		((uint32_t)bytes[1] << 8) |
		((uint32_t)bytes[2] << 16) |
		((uint32_t)bytes[3] << 24);
}

static uint64_t VLReadLE64(const uint8_t *bytes) {
	return (uint64_t)VLReadLE32(bytes) | ((uint64_t)VLReadLE32(bytes + 4) << 32);
}

static void VLWriteLE16(uint8_t *bytes, uint16_t value) {
	bytes[0] = (uint8_t)(value & 0xFF);
	bytes[1] = (uint8_t)((value >> 8) & 0xFF);
}

static void VLWriteLE32(uint8_t *bytes, uint32_t value) {
	bytes[0] = (uint8_t)(value & 0xFF);
	bytes[1] = (uint8_t)((value >> 8) & 0xFF);
	bytes[2] = (uint8_t)((value >> 16) & 0xFF);
	bytes[3] = (uint8_t)((value >> 24) & 0xFF);
}

#pragma mark - VLVirtioBufferDescriptor

@implementation VLVirtioBufferDescriptor

+ (instancetype)descriptorWithAddress:(uint64_t)address
							   length:(uint32_t)length
							 writable:(BOOL)writable {
	VLVirtioBufferDescriptor *descriptor = [[VLVirtioBufferDescriptor alloc] init];
	descriptor->_address = address;
	descriptor->_length = length;
	descriptor->_writable = writable;
	return descriptor;
}

@end

@implementation VLVirtioMMIODevice {
	VLGuestMemory *_guestMemory;
	VLInterruptController *_interruptController;
	uint32_t _interruptNumber;

	uint32_t _deviceFeaturesSel;
	uint32_t _driverFeatures;
	uint32_t _queueSelect;
	uint32_t _status;
	uint32_t _interruptStatus;
	VLVirtioQueueState _queues[VLVirtioMaximumQueues];
}

- (instancetype)initWithBaseAddress:(uint64_t)baseAddress
						guestMemory:(VLGuestMemory *)guestMemory
					interruptNumber:(uint32_t)interruptNumber
			  interruptController:(VLInterruptController *)interruptController {
	self = [super init];
	if (self) {
		_baseAddress = baseAddress;
		_regionSize = 0x1000;
		_guestMemory = guestMemory;
		_interruptController = interruptController;
		_interruptNumber = interruptNumber;
		for (uint32_t index = 0; index < VLVirtioMaximumQueues; index++) {
			_queues[index].align = 4096;
		}
	}
	return self;
}

#pragma mark - 子类默认实现

- (uint32_t)virtioDeviceID {
	return 0;
}

- (uint32_t)virtioDeviceFeatures {
	return 0;
}

- (uint32_t)queueNumMax {
	return 8;
}

- (uint32_t)handleDescriptorChain:(NSArray<VLVirtioBufferDescriptor *> *)chain
							 head:(uint16_t)head {
	return 0;
}

- (BOOL)completesChainImmediately {
	return YES;
}

- (uint32_t)readConfigAtOffset:(uint32_t)offset width:(uint32_t)width {
	return 0;
}

- (void)writeConfigAtOffset:(uint32_t)offset width:(uint32_t)width value:(uint32_t)value {
}

- (void)resetDevice {
}

#pragma mark - 寄存器

- (uint32_t)readAtOffset:(uint32_t)offset width:(uint32_t)width {
	if (offset >= VLVirtioConfigOffset) {
		return [self readConfigAtOffset:offset - VLVirtioConfigOffset width:width];
	}
	if (offset == VLVirtioRegisterMagic) {
		return 0x74726976;
	}
	if (offset == VLVirtioRegisterVersion) {
		return 1; // legacy v1，客户机按老队列布局访问
	}
	if (offset == VLVirtioRegisterDeviceID) {
		return [self virtioDeviceID];
	}
	if (offset == VLVirtioRegisterVendorID) {
		return 0x1AF4;
	}
	if (offset == VLVirtioRegisterDeviceFeatures) {
		return _deviceFeaturesSel == 0 ? [self virtioDeviceFeatures] : 0;
	}
	if (offset == VLVirtioRegisterQueueNumMax) {
		return [self queueNumMax];
	}
	if (offset == VLVirtioRegisterQueueNum) {
		return _queues[_queueSelect].num;
	}
	if (offset == VLVirtioRegisterQueueAlign) {
		return _queues[_queueSelect].align;
	}
	if (offset == VLVirtioRegisterQueuePFN) {
		return _queues[_queueSelect].pfn;
	}
	if (offset == VLVirtioRegisterInterruptStatus) {
		return _interruptStatus;
	}
	if (offset == VLVirtioRegisterStatus) {
		return _status;
	}
	return 0;
}

- (void)writeAtOffset:(uint32_t)offset width:(uint32_t)width value:(uint32_t)value {
	if (offset >= VLVirtioConfigOffset) {
		[self writeConfigAtOffset:offset - VLVirtioConfigOffset width:width value:value];
		return;
	}
	if (offset == VLVirtioRegisterDeviceFeaturesSel) {
		_deviceFeaturesSel = value;
		return;
	}
	if (offset == VLVirtioRegisterDriverFeatures) {
		_driverFeatures = value;
		return;
	}
	if (offset == VLVirtioRegisterDriverFeaturesSel) {
		return;
	}
	if (offset == VLVirtioRegisterQueueSel) {
		_queueSelect = value < VLVirtioMaximumQueues ? value : (VLVirtioMaximumQueues - 1);
		return;
	}
	if (offset == VLVirtioRegisterQueueNum) {
		_queues[_queueSelect].num = MIN(value, [self queueNumMax]);
		return;
	}
	if (offset == VLVirtioRegisterQueueAlign) {
		_queues[_queueSelect].align = value;
		return;
	}
	if (offset == VLVirtioRegisterQueuePFN) {
		_queues[_queueSelect].pfn = value;
		_queues[_queueSelect].lastAvailable = 0;
		return;
	}
	if (offset == VLVirtioRegisterQueueNotify) {
		[self processQueueAtIndex:value];
		return;
	}
	if (offset == VLVirtioRegisterInterruptACK) {
		_interruptStatus &= ~value;
		return;
	}
	if (offset == VLVirtioRegisterStatus) {
		[self writeStatus:value];
		return;
	}
}

- (void)writeStatus:(uint32_t)value {
	uint32_t previous = _status;
	_status = value;

	if (value == 0) {
		memset(_queues, 0, sizeof(_queues));
		for (uint32_t index = 0; index < VLVirtioMaximumQueues; index++) {
			_queues[index].align = 4096;
		}
		_interruptStatus = 0;
		_queueSelect = 0;
		[self resetDevice];
		return;
	}

	// DRIVER_OK：客户机驱动程序已经接管，后面才可能有队列通知。
	if ((previous & 0x4) == 0 && (value & 0x4) != 0) {
		[VLStartupLog log:@"virtio 设备 %u 驱动就绪（队列深度 %u）",
			(unsigned)[self virtioDeviceID], (unsigned)_queues[0].num];
	}
}

#pragma mark - 队列

- (void)raiseInterrupt {
	_interruptStatus |= 1;
	[_interruptController setIRQPending:_interruptNumber];
}

- (void)processQueueAtIndex:(uint32_t)index {
	if (index >= VLVirtioMaximumQueues || _guestMemory == nil) {
		return;
	}

	VLVirtioQueueState *state = &_queues[index];
	if (state->num == 0 || state->pfn == 0) {
		return;
	}

	uint64_t descriptorBase = (uint64_t)state->pfn * 4096ULL;
	uint64_t alignment = state->align >= 4096 ? state->align : 4096;
	uint64_t availableBase =
		descriptorBase + VLAlignUp64((uint64_t)state->num * 16ULL, alignment);

	const uint8_t *availableIndexPointer =
		[_guestMemory hostPointerForGuestAddress:availableBase + 2 length:2];
	if (availableIndexPointer == NULL) {
		return;
	}
	uint16_t availableIndex = VLReadLE16(availableIndexPointer);

	uint32_t processed = 0;
	while (state->lastAvailable != availableIndex &&
		   processed < VLVirtioMaximumNotificationsPerRun) {
		const uint8_t *ringEntry = [_guestMemory
			hostPointerForGuestAddress:availableBase + 4 + 2ULL * (state->lastAvailable % state->num)
								length:2];
		if (ringEntry == NULL) {
			break;
		}
		uint16_t head = VLReadLE16(ringEntry);

		NSArray<VLVirtioBufferDescriptor *> *chain =
			[self chainAtTable:descriptorBase head:head count:state->num];
		uint32_t usedLength = chain.count > 0
			? [self handleDescriptorChain:chain head:head]
			: 0;

		state->lastAvailable++;
		processed++;

		// 输入设备要等真有事件才回填 used，这里不能抢先标记完成。
		if ([self completesChainImmediately]) {
			[self writeUsedElementWithHead:head
									length:usedLength
								  queueIndex:index];
		}
	}

	if (processed > 0) {
		[self raiseInterrupt];
	}
}

- (void)completeChainWithHead:(uint16_t)head
					   length:(uint32_t)length
				   queueIndex:(uint32_t)queueIndex {
	[self writeUsedElementWithHead:head length:length queueIndex:queueIndex];
	[self raiseInterrupt];
}

- (void)writeUsedElementWithHead:(uint16_t)head
						  length:(uint32_t)length
					  queueIndex:(uint32_t)queueIndex {
	if (queueIndex >= VLVirtioMaximumQueues) {
		return;
	}
	VLVirtioQueueState *state = &_queues[queueIndex];
	if (state->num == 0 || state->pfn == 0) {
		return;
	}

	uint64_t descriptorBase = (uint64_t)state->pfn * 4096ULL;
	uint64_t alignment = state->align >= 4096 ? state->align : 4096;
	uint64_t availableBase =
		descriptorBase + VLAlignUp64((uint64_t)state->num * 16ULL, alignment);
	uint64_t usedBase =
		availableBase + VLAlignUp64(6ULL + (uint64_t)state->num * 2ULL, alignment);

	uint8_t *usedIndexPointer = [_guestMemory hostPointerForGuestAddress:usedBase + 2 length:2];
	if (usedIndexPointer == NULL) {
		return;
	}
	uint16_t usedIndex = VLReadLE16(usedIndexPointer);
	uint8_t *usedElement = [_guestMemory
		hostPointerForGuestAddress:usedBase + 4 + 8ULL * (usedIndex % state->num)
							length:8];
	if (usedElement == NULL) {
		return;
	}
	VLWriteLE32(usedElement, head);
	VLWriteLE32(usedElement + 4, length);
	VLWriteLE16(usedIndexPointer, (uint16_t)(usedIndex + 1));
}

- (NSArray<VLVirtioBufferDescriptor *> *)chainAtTable:(uint64_t)tableBase
												head:(uint16_t)head
											   count:(uint32_t)count {
	NSMutableArray<VLVirtioBufferDescriptor *> *chain = [NSMutableArray array];
	uint16_t current = head;

	for (uint32_t step = 0;
		 step < VLVirtioMaximumChainLength && step < count;
		 step++) {
		const uint8_t *descriptor = [_guestMemory
			hostPointerForGuestAddress:tableBase + 16ULL * current
								length:16];
		if (descriptor == NULL) {
			break;
		}

		uint64_t address = VLReadLE64(descriptor);
		uint32_t length = VLReadLE32(descriptor + 8);
		uint16_t flags = VLReadLE16(descriptor + 12);
		uint16_t next = VLReadLE16(descriptor + 14);

		[chain addObject:[VLVirtioBufferDescriptor descriptorWithAddress:address
																 length:length
															   writable:(flags & 0x2) != 0]];
		if ((flags & 0x1) == 0) {
			break;
		}
		current = next;
	}
	return chain;
}

@end
