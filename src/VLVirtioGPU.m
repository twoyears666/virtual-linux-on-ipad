#import "VLVirtioGPU.h"

#import <stdlib.h>
#import <string.h>

#import "VLGuestMemory.h"
#import "VLInterruptController.h"
#import "VLStartupLog.h"

// virtio-mmio 寄存器（legacy v1）
#define VL_MMIO_MAGIC 0x000
#define VL_MMIO_VERSION 0x004
#define VL_MMIO_DEVICE_ID 0x008
#define VL_MMIO_VENDOR_ID 0x00C
#define VL_MMIO_DEVICE_FEATURES 0x010
#define VL_MMIO_DEVICE_FEATURES_SEL 0x014
#define VL_MMIO_DRIVER_FEATURES 0x020
#define VL_MMIO_DRIVER_FEATURES_SEL 0x024
#define VL_MMIO_QUEUE_SEL 0x030
#define VL_MMIO_QUEUE_NUM_MAX 0x034
#define VL_MMIO_QUEUE_NUM 0x038
#define VL_MMIO_QUEUE_ALIGN 0x03C
#define VL_MMIO_QUEUE_PFN 0x040
#define VL_MMIO_QUEUE_NOTIFY 0x050
#define VL_MMIO_INTERRUPT_STATUS 0x060
#define VL_MMIO_INTERRUPT_ACK 0x064
#define VL_MMIO_STATUS 0x070
#define VL_MMIO_CONFIG 0x100

#define VL_MMIO_MAGIC_VALUE 0x74726976
#define VL_MMIO_VERSION_LEGACY 1
#define VL_VIRTIO_DEVICE_GPU 16
#define VL_VIRTIO_VENDOR_ID 0x1AF4
#define VL_MAXIMUM_QUEUE_SIZE 8
#define VL_STATUS_DRIVER_OK 4
#define VL_DESCRIPTOR_FLAG_NEXT 0x1
#define VL_DESCRIPTOR_FLAG_WRITE 0x2

// virtio-gpu 命令与响应
#define VL_GPU_CMD_GET_DISPLAY_INFO 0x0100
#define VL_GPU_CMD_RESOURCE_CREATE_2D 0x0101
#define VL_GPU_CMD_RESOURCE_UNREF 0x0102
#define VL_GPU_CMD_SET_SCANOUT 0x0103
#define VL_GPU_CMD_RESOURCE_FLUSH 0x0104
#define VL_GPU_CMD_TRANSFER_TO_HOST_2D 0x0105
#define VL_GPU_CMD_RESOURCE_ATTACH_BACKING 0x0106
#define VL_GPU_CMD_RESOURCE_DETACH_BACKING 0x0107
#define VL_GPU_RESP_OK_NODATA 0x1100
#define VL_GPU_RESP_ERR_UNSPEC 0x1202
#define VL_GPU_RESP_ERR_INVALID_RESOURCE 0x1203
#define VL_GPU_COMMAND_HEADER_SIZE 24

static uint64_t VLAlignUp(uint64_t value, uint64_t alignment) {
	if (alignment == 0) {
		return value;
	}
	return (value + alignment - 1) & ~(alignment - 1);
}

static uint32_t VLReadLE32(const uint8_t *bytes) {
	return (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) | ((uint32_t)bytes[2] << 16) |
		((uint32_t)bytes[3] << 24);
}

static uint64_t VLReadLE64(const uint8_t *bytes) {
	return (uint64_t)VLReadLE32(bytes) | ((uint64_t)VLReadLE32(bytes + 4) << 32);
}

static void VLWriteLE32(uint8_t *bytes, uint32_t value) {
	bytes[0] = (uint8_t)(value & 0xFF);
	bytes[1] = (uint8_t)((value >> 8) & 0xFF);
	bytes[2] = (uint8_t)((value >> 16) & 0xFF);
	bytes[3] = (uint8_t)((value >> 24) & 0xFF);
}

static void VLWriteLE64(uint8_t *bytes, uint64_t value) {
	VLWriteLE32(bytes, (uint32_t)(value & 0xFFFFFFFF));
	VLWriteLE32(bytes + 4, (uint32_t)(value >> 32));
}

/// 描述符链里的一项。
@interface VLVirtioDescriptor : NSObject
@property (nonatomic, assign) uint64_t address;
@property (nonatomic, assign) uint32_t length;
@property (nonatomic, assign) BOOL writable;
@end

@implementation VLVirtioDescriptor
@end

/// 一块 2D 资源：创建尺寸 + 客户机后备内存分块。
@interface VLVirtioGPUResource : NSObject
@property (nonatomic, assign) uint32_t identifier;
@property (nonatomic, assign) uint32_t width;
@property (nonatomic, assign) uint32_t height;
@property (nonatomic, assign) uint32_t format;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *chunkAddresses;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *chunkLengths;
@end

@implementation VLVirtioGPUResource

- (instancetype)init {
	self = [super init];
	if (self) {
		_chunkAddresses = [NSMutableArray array];
		_chunkLengths = [NSMutableArray array];
	}
	return self;
}

@end

@implementation VLVirtioGPU {
	VLGuestMemory *_guestMemory;
	VLInterruptController *_interruptController;
	uint32_t _interruptNumber;

	uint32_t _deviceFeaturesSel;
	uint32_t _driverFeaturesSel;
	uint32_t _queueSel;
	uint32_t _queueNum;
	uint32_t _queueAlign;
	uint32_t _queuePFN;
	uint32_t _status;
	uint32_t _interruptStatus;
	uint16_t _lastAvailableIndex;
	BOOL _driverOK;

	NSMutableDictionary<NSNumber *, VLVirtioGPUResource *> *_resources;
	uint32_t _scanoutResourceIdentifier;
	BOOL _scanoutEnabled;
	uint32_t _framebufferWidth;
	uint32_t _framebufferHeight;
	uint8_t *_framebuffer;
}

- (instancetype)initWithBaseAddress:(uint64_t)baseAddress
						guestMemory:(VLGuestMemory *)guestMemory
					interruptNumber:(uint32_t)interruptNumber
			  interruptController:(VLInterruptController *)interruptController
					   displayWidth:(uint32_t)displayWidth
					  displayHeight:(uint32_t)displayHeight {
	self = [super init];
	if (self) {
		_baseAddress = baseAddress;
		_regionSize = 0x1000;
		_guestMemory = guestMemory;
		_interruptController = interruptController;
		_interruptNumber = interruptNumber;
		_displayWidth = displayWidth > 0 ? displayWidth : 1024;
		_displayHeight = displayHeight > 0 ? displayHeight : 768;
		_resources = [NSMutableDictionary dictionary];
		_queueAlign = 4096;
		_framebufferWidth = self.displayWidth;
		_framebufferHeight = self.displayHeight;
		_framebuffer = calloc(1, (size_t)_framebufferWidth * _framebufferHeight * 4);
	}
	return self;
}

- (void)dealloc {
	free(_framebuffer);
}

#pragma mark - 寄存器

- (uint32_t)readAtOffset:(uint32_t)offset width:(uint32_t)width {
	if (offset >= VL_MMIO_CONFIG) {
		// virtio_gpu_config：events_read / events_clear / num_scanouts / num_capsets
		uint32_t configOffset = offset - VL_MMIO_CONFIG;
		return (configOffset >= 8 && configOffset < 12) ? 1 : 0;
	}

	if (offset == VL_MMIO_MAGIC) {
		return VL_MMIO_MAGIC_VALUE;
	}
	if (offset == VL_MMIO_VERSION) {
		return VL_MMIO_VERSION_LEGACY;
	}
	if (offset == VL_MMIO_DEVICE_ID) {
		return VL_VIRTIO_DEVICE_GPU;
	}
	if (offset == VL_MMIO_VENDOR_ID) {
		return VL_VIRTIO_VENDOR_ID;
	}
	if (offset == VL_MMIO_DEVICE_FEATURES) {
		// 不支持 virgl / edid / blob，特性位全 0。
		return 0;
	}
	if (offset == VL_MMIO_DEVICE_FEATURES_SEL) {
		return _deviceFeaturesSel;
	}
	if (offset == VL_MMIO_DRIVER_FEATURES_SEL) {
		return _driverFeaturesSel;
	}
	if (offset == VL_MMIO_QUEUE_SEL) {
		return _queueSel;
	}
	if (offset == VL_MMIO_QUEUE_NUM_MAX) {
		return VL_MAXIMUM_QUEUE_SIZE;
	}
	if (offset == VL_MMIO_QUEUE_NUM) {
		return _queueNum;
	}
	if (offset == VL_MMIO_QUEUE_ALIGN) {
		return _queueAlign;
	}
	if (offset == VL_MMIO_QUEUE_PFN) {
		return _queuePFN;
	}
	if (offset == VL_MMIO_INTERRUPT_STATUS) {
		return _interruptStatus;
	}
	if (offset == VL_MMIO_STATUS) {
		return _status;
	}
	return 0;
}

- (void)writeAtOffset:(uint32_t)offset width:(uint32_t)width value:(uint32_t)value {
	if (offset >= VL_MMIO_CONFIG) {
		return;
	}
	if (offset == VL_MMIO_DEVICE_FEATURES_SEL) {
		_deviceFeaturesSel = value;
		return;
	}
	if (offset == VL_MMIO_DRIVER_FEATURES_SEL) {
		_driverFeaturesSel = value;
		return;
	}
	if (offset == VL_MMIO_QUEUE_SEL) {
		_queueSel = value;
		return;
	}
	if (offset == VL_MMIO_QUEUE_NUM) {
		_queueNum = MIN(value, VL_MAXIMUM_QUEUE_SIZE);
		return;
	}
	if (offset == VL_MMIO_QUEUE_ALIGN) {
		_queueAlign = value > 0 ? value : 4096;
		return;
	}
	if (offset == VL_MMIO_QUEUE_PFN) {
		_queuePFN = value;
		_lastAvailableIndex = 0;
		return;
	}
	if (offset == VL_MMIO_QUEUE_NOTIFY) {
		[self processQueue];
		return;
	}
	if (offset == VL_MMIO_INTERRUPT_ACK) {
		_interruptStatus &= ~value;
		if ((_interruptStatus & 1) == 0) {
			[_interruptController clearIRQPending:_interruptNumber];
		}
		return;
	}
	if (offset == VL_MMIO_STATUS) {
		[self writeStatus:value];
	}
}

- (void)writeStatus:(uint32_t)value {
	if (value == 0) {
		// 复位：队列指针与状态清空，资源由客户机重新创建。
		_driverOK = NO;
		_queuePFN = 0;
		_queueNum = 0;
		_lastAvailableIndex = 0;
		_interruptStatus = 0;
		_status = 0;
		return;
	}
	_status = value;
	BOOL ready = (value & VL_STATUS_DRIVER_OK) != 0;
	if (ready != _driverOK) {
		_driverOK = ready;
		[VLStartupLog log:@"virtio-gpu %@", ready ? @"驱动就绪" : @"驱动退出"];
	}
}

#pragma mark - 队列

- (void)processQueue {
	if (!_driverOK || _queuePFN == 0 || _queueNum == 0) {
		return;
	}

	uint64_t align = MAX((uint64_t)_queueAlign, 4096);
	uint64_t descriptorBase = (uint64_t)_queuePFN * 4096;
	uint64_t availableBase = descriptorBase + VLAlignUp(16 * (uint64_t)_queueNum, align);
	uint64_t usedBase = availableBase + VLAlignUp(6 + 2 * (uint64_t)_queueNum, align);

	uint8_t *availableIndexBytes = [_guestMemory hostPointerForGuestAddress:availableBase + 2 length:2];
	uint8_t *usedIndexBytes = [_guestMemory hostPointerForGuestAddress:usedBase + 2 length:2];
	if (availableIndexBytes == NULL || usedIndexBytes == NULL) {
		[VLStartupLog log:@"virtio-gpu 队列地址无效：pfn=%u", _queuePFN];
		return;
	}

	uint16_t availableIndex = 0;
	memcpy(&availableIndex, availableIndexBytes, 2);

	BOOL processedAny = NO;
	uint32_t guard = 0;
	while (_lastAvailableIndex != availableIndex && guard < 32) {
		guard++;
		uint64_t slot = availableBase + 4 + (uint64_t)(_lastAvailableIndex % _queueNum) * 2;
		uint8_t *slotBytes = [_guestMemory hostPointerForGuestAddress:slot length:2];
		if (slotBytes == NULL) {
			break;
		}
		uint16_t head = 0;
		memcpy(&head, slotBytes, 2);

		uint32_t usedLength = [self handleChainAtTable:descriptorBase head:head];

		uint16_t usedIndex = 0;
		memcpy(&usedIndex, usedIndexBytes, 2);
		uint64_t elementOffset = usedBase + 4 + (uint64_t)(usedIndex % _queueNum) * 8;
		uint8_t *element = [_guestMemory hostPointerForGuestAddress:elementOffset length:8];
		if (element != NULL) {
			VLWriteLE32(element, head);
			VLWriteLE32(element + 4, usedLength);
			usedIndex = (uint16_t)(usedIndex + 1);
			memcpy(usedIndexBytes, &usedIndex, 2);
		}

		_lastAvailableIndex = (uint16_t)(_lastAvailableIndex + 1);
		processedAny = YES;
	}

	if (!processedAny) {
		return;
	}

	// 通知客户机：有已用缓冲区。
	_interruptStatus |= 1;
	[_interruptController setIRQPending:_interruptNumber];
}

- (uint32_t)handleChainAtTable:(uint64_t)tableBase head:(uint16_t)head {
	NSMutableArray<VLVirtioDescriptor *> *chain = [NSMutableArray array];
	uint16_t current = head;
	uint32_t guard = 0;
	while (guard < 16) {
		guard++;
		uint8_t *bytes = [_guestMemory hostPointerForGuestAddress:tableBase + (uint64_t)current * 16 length:16];
		if (bytes == NULL) {
			break;
		}
		VLVirtioDescriptor *descriptor = [[VLVirtioDescriptor alloc] init];
		descriptor.address = VLReadLE64(bytes);
		descriptor.length = VLReadLE32(bytes + 8);
		uint16_t flags = 0;
		memcpy(&flags, bytes + 12, 2);
		descriptor.writable = (flags & VL_DESCRIPTOR_FLAG_WRITE) != 0;
		[chain addObject:descriptor];
		if ((flags & VL_DESCRIPTOR_FLAG_NEXT) == 0) {
			break;
		}
		uint16_t next = 0;
		memcpy(&next, bytes + 14, 2);
		current = next;
	}
	return [self dispatchChain:chain];
}

#pragma mark - 命令

- (uint32_t)dispatchChain:(NSArray<VLVirtioDescriptor *> *)chain {
	if (chain.count == 0) {
		return 0;
	}
	VLVirtioDescriptor *request = chain.firstObject;
	if (request.length < VL_GPU_COMMAND_HEADER_SIZE) {
		return 0;
	}
	uint8_t *header = [_guestMemory hostPointerForGuestAddress:request.address
													   length:VL_GPU_COMMAND_HEADER_SIZE];
	if (header == NULL) {
		return 0;
	}

	uint32_t command = VLReadLE32(header);
	uint64_t fence = VLReadLE64(header + 8);

	if (command == VL_GPU_CMD_GET_DISPLAY_INFO) {
		return [self respondGetDisplayInfo:chain fence:fence];
	}
	if (command == VL_GPU_CMD_RESOURCE_CREATE_2D) {
		return [self handleResourceCreate:chain fence:fence];
	}
	if (command == VL_GPU_CMD_RESOURCE_ATTACH_BACKING) {
		return [self handleAttachBacking:chain fence:fence];
	}
	if (command == VL_GPU_CMD_RESOURCE_DETACH_BACKING) {
		return [self handleDetachBacking:chain fence:fence];
	}
	if (command == VL_GPU_CMD_SET_SCANOUT) {
		return [self handleSetScanout:chain fence:fence];
	}
	if (command == VL_GPU_CMD_RESOURCE_FLUSH) {
		return [self handleFlush:chain fence:fence];
	}
	if (command == VL_GPU_CMD_TRANSFER_TO_HOST_2D) {
		return [self handleTransfer:chain fence:fence];
	}
	if (command == VL_GPU_CMD_RESOURCE_UNREF) {
		return [self handleUnref:chain fence:fence];
	}
	return [self respond:chain type:VL_GPU_RESP_ERR_UNSPEC fence:fence payload:nil];
}

- (uint8_t *)commandPointerForChain:(NSArray<VLVirtioDescriptor *> *)chain {
	VLVirtioDescriptor *request = chain.firstObject;
	return [_guestMemory hostPointerForGuestAddress:request.address length:request.length];
}

/// 往第一个可写描述符写「响应头 + 附加数据」，返回实际字节数。
- (uint32_t)respond:(NSArray<VLVirtioDescriptor *> *)chain
			   type:(uint32_t)type
			  fence:(uint64_t)fence
			payload:(NSData *)payload {
	VLVirtioDescriptor *target = nil;
	for (VLVirtioDescriptor *descriptor in chain) {
		if (descriptor.writable) {
			target = descriptor;
			break;
		}
	}
	if (target == nil || target.length < VL_GPU_COMMAND_HEADER_SIZE) {
		return 0;
	}
	uint8_t *buffer = [_guestMemory hostPointerForGuestAddress:target.address length:target.length];
	if (buffer == NULL) {
		return 0;
	}

	memset(buffer, 0, VL_GPU_COMMAND_HEADER_SIZE);
	VLWriteLE32(buffer, type);
	VLWriteLE64(buffer + 8, fence);
	uint32_t written = VL_GPU_COMMAND_HEADER_SIZE;

	if (payload.length > 0) {
		NSUInteger available = target.length - VL_GPU_COMMAND_HEADER_SIZE;
		NSUInteger count = MIN(payload.length, available);
		memcpy(buffer + VL_GPU_COMMAND_HEADER_SIZE, payload.bytes, count);
		written += (uint32_t)count;
	}
	return written;
}

- (uint32_t)respondGetDisplayInfo:(NSArray<VLVirtioDescriptor *> *)chain fence:(uint64_t)fence {
	// 响应头之后是 16 个 pmodes，每个 24 字节：x/y/w/h/enabled/flags。
	NSMutableData *payload = [NSMutableData dataWithLength:16 * 24];
	uint8_t *bytes = payload.mutableBytes;
	VLWriteLE32(bytes + 8, self.displayWidth);
	VLWriteLE32(bytes + 12, self.displayHeight);
	VLWriteLE32(bytes + 16, 1);
	return [self respond:chain type:VL_GPU_RESP_OK_NODATA fence:fence payload:payload];
}

- (VLVirtioGPUResource *)resourceFromChain:(NSArray<VLVirtioDescriptor *> *)chain payloadOffset:(uint32_t)payloadOffset {
	uint8_t *command = [self commandPointerForChain:chain];
	VLVirtioDescriptor *request = chain.firstObject;
	if (command == NULL || request.length < payloadOffset + 4) {
		return nil;
	}
	uint32_t identifier = VLReadLE32(command + payloadOffset);
	return _resources[@(identifier)];
}

- (uint32_t)handleResourceCreate:(NSArray<VLVirtioDescriptor *> *)chain fence:(uint64_t)fence {
	uint8_t *command = [self commandPointerForChain:chain];
	VLVirtioDescriptor *request = chain.firstObject;
	if (command == NULL || request.length < VL_GPU_COMMAND_HEADER_SIZE + 16) {
		return [self respond:chain type:VL_GPU_RESP_ERR_UNSPEC fence:fence payload:nil];
	}
	uint32_t offset = VL_GPU_COMMAND_HEADER_SIZE;

	VLVirtioGPUResource *resource = [[VLVirtioGPUResource alloc] init];
	resource.identifier = VLReadLE32(command + offset);
	resource.format = VLReadLE32(command + offset + 4);
	resource.width = VLReadLE32(command + offset + 8);
	resource.height = VLReadLE32(command + offset + 12);
	_resources[@(resource.identifier)] = resource;
	[VLStartupLog log:@"virtio-gpu 资源创建 id=%u %ux%u", resource.identifier, resource.width, resource.height];
	return [self respond:chain type:VL_GPU_RESP_OK_NODATA fence:fence payload:nil];
}

- (uint32_t)handleAttachBacking:(NSArray<VLVirtioDescriptor *> *)chain fence:(uint64_t)fence {
	uint8_t *command = [self commandPointerForChain:chain];
	VLVirtioDescriptor *request = chain.firstObject;
	if (command == NULL || request.length < VL_GPU_COMMAND_HEADER_SIZE + 8) {
		return [self respond:chain type:VL_GPU_RESP_ERR_UNSPEC fence:fence payload:nil];
	}
	uint32_t offset = VL_GPU_COMMAND_HEADER_SIZE;
	uint32_t identifier = VLReadLE32(command + offset);
	uint32_t entryCount = VLReadLE32(command + offset + 4);
	VLVirtioGPUResource *resource = _resources[@(identifier)];
	if (resource == nil) {
		return [self respond:chain type:VL_GPU_RESP_ERR_INVALID_RESOURCE fence:fence payload:nil];
	}

	[resource.chunkAddresses removeAllObjects];
	[resource.chunkLengths removeAllObjects];
	for (uint32_t index = 0; index < entryCount; index++) {
		uint32_t entryOffset = offset + 8 + index * 16;
		if (request.length < entryOffset + 16) {
			break;
		}
		uint64_t address = VLReadLE64(command + entryOffset);
		uint32_t length = VLReadLE32(command + entryOffset + 8);
		[resource.chunkAddresses addObject:@(address)];
		[resource.chunkLengths addObject:@(length)];
	}
	[VLStartupLog log:@"virtio-gpu 后备内存 id=%u 分块=%u", identifier, entryCount];
	return [self respond:chain type:VL_GPU_RESP_OK_NODATA fence:fence payload:nil];
}

- (uint32_t)handleDetachBacking:(NSArray<VLVirtioDescriptor *> *)chain fence:(uint64_t)fence {
	VLVirtioGPUResource *resource =
		[self resourceFromChain:chain payloadOffset:VL_GPU_COMMAND_HEADER_SIZE];
	if (resource != nil) {
		[resource.chunkAddresses removeAllObjects];
		[resource.chunkLengths removeAllObjects];
	}
	return [self respond:chain type:VL_GPU_RESP_OK_NODATA fence:fence payload:nil];
}

- (uint32_t)handleSetScanout:(NSArray<VLVirtioDescriptor *> *)chain fence:(uint64_t)fence {
	uint8_t *command = [self commandPointerForChain:chain];
	VLVirtioDescriptor *request = chain.firstObject;
	// rect(16) + scanout_id(4) + resource_id(4)
	if (command == NULL || request.length < VL_GPU_COMMAND_HEADER_SIZE + 24) {
		return [self respond:chain type:VL_GPU_RESP_ERR_UNSPEC fence:fence payload:nil];
	}
	uint32_t offset = VL_GPU_COMMAND_HEADER_SIZE;
	uint32_t scanoutID = VLReadLE32(command + offset + 16);
	uint32_t identifier = VLReadLE32(command + offset + 20);
	if (scanoutID == 0) {
		_scanoutResourceIdentifier = identifier;
		_scanoutEnabled = YES;
		[self resizeFramebufferForResource:identifier];
		[VLStartupLog log:@"virtio-gpu 扫描输出绑定资源 id=%u", identifier];
	}
	return [self respond:chain type:VL_GPU_RESP_OK_NODATA fence:fence payload:nil];
}

- (uint32_t)handleFlush:(NSArray<VLVirtioDescriptor *> *)chain fence:(uint64_t)fence {
	// rect(16) + resource_id(4) + padding(4)
	VLVirtioGPUResource *resource =
		[self resourceFromChain:chain payloadOffset:VL_GPU_COMMAND_HEADER_SIZE + 16];
	if (resource != nil) {
		[self publishFramebuffer];
	}
	return [self respond:chain type:VL_GPU_RESP_OK_NODATA fence:fence payload:nil];
}

- (uint32_t)handleTransfer:(NSArray<VLVirtioDescriptor *> *)chain fence:(uint64_t)fence {
	uint8_t *command = [self commandPointerForChain:chain];
	VLVirtioDescriptor *request = chain.firstObject;
	// rect(16) + offset(8) + resource_id(4) + padding(4)
	if (command == NULL || request.length < VL_GPU_COMMAND_HEADER_SIZE + 32) {
		return [self respond:chain type:VL_GPU_RESP_ERR_UNSPEC fence:fence payload:nil];
	}
	uint32_t offset = VL_GPU_COMMAND_HEADER_SIZE;
	uint32_t x = VLReadLE32(command + offset);
	uint32_t y = VLReadLE32(command + offset + 4);
	uint32_t width = VLReadLE32(command + offset + 8);
	uint32_t height = VLReadLE32(command + offset + 12);
	uint64_t resourceOffset = VLReadLE64(command + offset + 16);
	uint32_t identifier = VLReadLE32(command + offset + 24);

	VLVirtioGPUResource *resource = _resources[@(identifier)];
	if (resource == nil) {
		return [self respond:chain type:VL_GPU_RESP_ERR_INVALID_RESOURCE fence:fence payload:nil];
	}
	[self copyResource:resource rectX:x rectY:y width:width height:height resourceOffset:resourceOffset];
	return [self respond:chain type:VL_GPU_RESP_OK_NODATA fence:fence payload:nil];
}

- (uint32_t)handleUnref:(NSArray<VLVirtioDescriptor *> *)chain fence:(uint64_t)fence {
	VLVirtioGPUResource *resource =
		[self resourceFromChain:chain payloadOffset:VL_GPU_COMMAND_HEADER_SIZE];
	if (resource != nil) {
		[_resources removeObjectForKey:@(resource.identifier)];
		if (resource.identifier == _scanoutResourceIdentifier) {
			_scanoutEnabled = NO;
		}
	}
	return [self respond:chain type:VL_GPU_RESP_OK_NODATA fence:fence payload:nil];
}

#pragma mark - 画面

- (void)resizeFramebufferForResource:(uint32_t)identifier {
	VLVirtioGPUResource *resource = _resources[@(identifier)];
	uint32_t width = resource.width > 0 ? resource.width : self.displayWidth;
	uint32_t height = resource.height > 0 ? resource.height : self.displayHeight;
	if (width == _framebufferWidth && height == _framebufferHeight) {
		return;
	}
	uint8_t *framebuffer = calloc(1, (size_t)width * height * 4);
	if (framebuffer == NULL) {
		return;
	}
	free(_framebuffer);
	_framebuffer = framebuffer;
	_framebufferWidth = width;
	_framebufferHeight = height;
}

- (void)copyResource:(VLVirtioGPUResource *)resource
			   rectX:(uint32_t)x
			   rectY:(uint32_t)y
			   width:(uint32_t)width
			  height:(uint32_t)height
	  resourceOffset:(uint64_t)offset {
	if (_framebuffer == NULL || resource.chunkAddresses.count == 0) {
		return;
	}
	if (resource.width == 0 || resource.height == 0) {
		return;
	}

	uint32_t clampedX = MIN(x, resource.width);
	uint32_t clampedY = MIN(y, resource.height);
	uint32_t copyWidth = MIN(width, resource.width - clampedX);
	uint32_t copyHeight = MIN(height, resource.height - clampedY);
	if (copyWidth == 0 || copyHeight == 0 || clampedX >= _framebufferWidth) {
		return;
	}

	uint64_t chunkStart = resource.chunkAddresses.firstObject.unsignedLongLongValue;
	uint64_t chunkLength = resource.chunkLengths.firstObject.unsignedLongLongValue;
	if (chunkLength == 0) {
		return;
	}
	uint32_t destinationWidth = MIN(copyWidth, _framebufferWidth - clampedX) * 4;

	for (uint32_t row = 0; row < copyHeight; row++) {
		uint32_t sourceY = clampedY + row;
		if (sourceY >= _framebufferHeight) {
			break;
		}
		uint64_t sourceOffset = offset + (uint64_t)(sourceY * resource.width + clampedX) * 4;
		if (sourceOffset + destinationWidth > chunkLength) {
			break;
		}
		uint8_t *source = [_guestMemory hostPointerForGuestAddress:chunkStart + sourceOffset
															length:destinationWidth];
		if (source == NULL) {
			break;
		}
		size_t destinationOffset = ((size_t)sourceY * _framebufferWidth + clampedX) * 4;
		memcpy(_framebuffer + destinationOffset, source, destinationWidth);
	}
}

- (void)publishFramebuffer {
	if (!_scanoutEnabled || _framebuffer == NULL || self.frameHandler == nil) {
		return;
	}
	size_t byteCount = (size_t)_framebufferWidth * _framebufferHeight * 4;
	NSData *frame = [NSData dataWithBytes:_framebuffer length:byteCount];
	self.frameHandler(_framebufferWidth, _framebufferHeight, frame);
}

@end
