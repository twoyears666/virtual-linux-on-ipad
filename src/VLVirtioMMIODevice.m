// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 twoyears666

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

// modern v2 多出来的队列地址寄存器：描述符区、驱动区（avail）、设备区（used）分开给。
#define VLVirtioRegisterQueueReady 0x044
#define VLVirtioRegisterQueueDescLow 0x080
#define VLVirtioRegisterQueueDescHigh 0x084
#define VLVirtioRegisterQueueDriverLow 0x090
#define VLVirtioRegisterQueueDriverHigh 0x094
#define VLVirtioRegisterQueueDeviceLow 0x0A0
#define VLVirtioRegisterQueueDeviceHigh 0x0A4
#define VLVirtioRegisterConfigGeneration 0x0FC
#define VLVirtioConfigOffset 0x100

#define VLVirtioMaximumQueues 2
#define VLVirtioMaximumChainLength 16
#define VLVirtioMaximumNotificationsPerRun 32

static uint64_t VLAlignUp64(uint64_t value, uint64_t alignment);

typedef struct {
	uint32_t num;
	uint32_t align;
	/// legacy v1：描述符表的页帧号；modern v2 时代码改用下面的三个地址。
	uint32_t pfn;
	/// modern v2：三个区域各自的客户机物理地址，由 QueueDescLow/High 等寄存器写入。
	uint64_t descAddress;
	uint64_t driverAddress;
	uint64_t deviceAddress;
	BOOL ready;
	uint32_t lastAvailable;
} VLVirtioQueueState;

/// 队列三个区域的地址。modern 优先用客户机写进来的三个地址，
/// 没写就按 legacy 的 pfn + 4 KB 对齐规则推出来。
static void VLVirtioQueueLayout(VLVirtioQueueState *state,
								uint64_t *descriptorBase,
								uint64_t *availableBase,
								uint64_t *usedBase) {
	if (state->descAddress != 0) {
		*descriptorBase = state->descAddress;
		*availableBase = state->driverAddress != 0
			? state->driverAddress
			: state->descAddress + (uint64_t)state->num * 16ULL;
		*usedBase = state->deviceAddress != 0
			? state->deviceAddress
			: VLAlignUp64(*availableBase + 6ULL + (uint64_t)state->num * 2ULL, 4096);
		return;
	}

	uint64_t legacyDescriptorBase = (uint64_t)state->pfn * 4096ULL;
	uint64_t alignment = state->align >= 4096 ? state->align : 4096;
	*descriptorBase = legacyDescriptorBase;
	*availableBase = legacyDescriptorBase + VLAlignUp64((uint64_t)state->num * 16ULL, alignment);
	*usedBase = *availableBase + VLAlignUp64(6ULL + (uint64_t)state->num * 2ULL, alignment);
}

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
							 head:(uint16_t)head
					   queueIndex:(uint32_t)queueIndex {
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
		// modern v2：队列用 QueueReady + 三段地址寄存器，内核会走现代 virtio 路径，
		// 不再有 legacy 的 PFN/对齐规则，也不再打「legacy 将来不支援」的警告。
		return 2;
	}
	if (offset == VLVirtioRegisterDeviceID) {
		return [self virtioDeviceID];
	}
	if (offset == VLVirtioRegisterVendorID) {
		return 0x1AF4;
	}
	if (offset == VLVirtioRegisterDeviceFeatures) {
		if (_deviceFeaturesSel == 0) {
			return [self virtioDeviceFeatures];
		}
		// 高 32 位的 bit 0 就是 VIRTIO_F_VERSION_1（总第 32 位）：
		// modern 设备必须声明它，否则内核拒绝按 v2 驱动。
		return _deviceFeaturesSel == 1 ? 1u : 0u;
	}
	if (offset == VLVirtioRegisterQueueNumMax) {
		return [self queueNumMax];
	}
	if (offset == VLVirtioRegisterQueueReady) {
		return _queues[_queueSelect].ready ? 1 : 0;
	}
	if (offset == VLVirtioRegisterQueueDescLow) {
		return (uint32_t)(_queues[_queueSelect].descAddress & 0xFFFFFFFF);
	}
	if (offset == VLVirtioRegisterQueueDescHigh) {
		return (uint32_t)(_queues[_queueSelect].descAddress >> 32);
	}
	if (offset == VLVirtioRegisterQueueDriverLow) {
		return (uint32_t)(_queues[_queueSelect].driverAddress & 0xFFFFFFFF);
	}
	if (offset == VLVirtioRegisterQueueDriverHigh) {
		return (uint32_t)(_queues[_queueSelect].driverAddress >> 32);
	}
	if (offset == VLVirtioRegisterQueueDeviceLow) {
		return (uint32_t)(_queues[_queueSelect].deviceAddress & 0xFFFFFFFF);
	}
	if (offset == VLVirtioRegisterQueueDeviceHigh) {
		return (uint32_t)(_queues[_queueSelect].deviceAddress >> 32);
	}
	if (offset == VLVirtioRegisterConfigGeneration) {
		return 0;
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
	// modern v2 的队列描述：QueueReady + 三段地址（描述符 / 驱动 / 设备）。
	if (offset == VLVirtioRegisterQueueReady) {
		_queues[_queueSelect].ready = (value & 1) != 0;
		// 现代 virtio-mmio 驱动以 QueueNumMax 为准，不一定会写 QueueNum：
		// 0.2.3 日志里四个设备挂上时都是「队列深度 0」，块设备的通知会被
		// processQueueAtIndex 开头的 num==0 判断直接丢掉。这里按最大值兜底。
		if (_queues[_queueSelect].ready && _queues[_queueSelect].num == 0) {
			_queues[_queueSelect].num = [self queueNumMax];
		}
		_queues[_queueSelect].lastAvailable = 0;
		return;
	}
	if (offset == VLVirtioRegisterQueueDescLow) {
		_queues[_queueSelect].descAddress =
			(_queues[_queueSelect].descAddress & ~0xFFFFFFFFULL) | (uint64_t)value;
		return;
	}
	if (offset == VLVirtioRegisterQueueDescHigh) {
		_queues[_queueSelect].descAddress =
			(_queues[_queueSelect].descAddress & 0xFFFFFFFFULL) | ((uint64_t)value << 32);
		return;
	}
	if (offset == VLVirtioRegisterQueueDriverLow) {
		_queues[_queueSelect].driverAddress =
			(_queues[_queueSelect].driverAddress & ~0xFFFFFFFFULL) | (uint64_t)value;
		return;
	}
	if (offset == VLVirtioRegisterQueueDriverHigh) {
		_queues[_queueSelect].driverAddress =
			(_queues[_queueSelect].driverAddress & 0xFFFFFFFFULL) | ((uint64_t)value << 32);
		return;
	}
	if (offset == VLVirtioRegisterQueueDeviceLow) {
		_queues[_queueSelect].deviceAddress =
			(_queues[_queueSelect].deviceAddress & ~0xFFFFFFFFULL) | (uint64_t)value;
		return;
	}
	if (offset == VLVirtioRegisterQueueDeviceHigh) {
		_queues[_queueSelect].deviceAddress =
			(_queues[_queueSelect].deviceAddress & 0xFFFFFFFFULL) | ((uint64_t)value << 32);
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
	if (state->num == 0 || (state->pfn == 0 && state->descAddress == 0)) {
		return;
	}
	// modern 的队列要先由驱动写 QueueReady=1 才算就绪，通知才会被处理。
	if (state->descAddress != 0 && !state->ready) {
		return;
	}

	uint64_t descriptorBase = 0;
	uint64_t availableBase = 0;
	uint64_t usedBase = 0;
	VLVirtioQueueLayout(state, &descriptorBase, &availableBase, &usedBase);
	(void)usedBase;

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
			? [self handleDescriptorChain:chain head:head queueIndex:index]
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
	if (state->num == 0 || (state->pfn == 0 && state->descAddress == 0)) {
		return;
	}

	uint64_t descriptorBase = 0;
	uint64_t availableBase = 0;
	uint64_t usedBase = 0;
	VLVirtioQueueLayout(state, &descriptorBase, &availableBase, &usedBase);
	(void)descriptorBase;
	(void)availableBase;

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
