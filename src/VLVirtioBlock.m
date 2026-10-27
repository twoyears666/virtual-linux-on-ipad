#import "VLVirtioBlock.h"

#import <fcntl.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

#import "VLGuestMemory.h"
#import "VLStartupLog.h"

#define VLBlockSectorSize 512
#define VLBlockQueueNumMax 64
#define VLBlockMaximumTransferSize 0x80000

#define VLBlockRequestIn 0
#define VLBlockRequestOut 1
#define VLBlockRequestFlush 4

#define VLBlockStatusOkay 0
#define VLBlockStatusIOError 1
#define VLBlockStatusUnsupported 2

static uint32_t VLBlockReadLE32(const uint8_t *bytes) {
	return (uint32_t)bytes[0] |
		((uint32_t)bytes[1] << 8) |
		((uint32_t)bytes[2] << 16) |
		((uint32_t)bytes[3] << 24);
}

static uint64_t VLBlockReadLE64(const uint8_t *bytes) {
	return (uint64_t)VLBlockReadLE32(bytes) | ((uint64_t)VLBlockReadLE32(bytes + 4) << 32);
}

@implementation VLVirtioBlock {
	int _descriptor;
	uint64_t _capacityInBytes;
}

- (instancetype)initWithBaseAddress:(uint64_t)baseAddress
						guestMemory:(VLGuestMemory *)guestMemory
					interruptNumber:(uint32_t)interruptNumber
			  interruptController:(VLInterruptController *)interruptController
						  imagePath:(NSString *)imagePath
						   readOnly:(BOOL)readOnly {
	self = [super initWithBaseAddress:baseAddress
						 guestMemory:guestMemory
					 interruptNumber:interruptNumber
				   interruptController:interruptController];
	if (self) {
		_imagePath = [imagePath copy];
		_readOnly = readOnly;
		_descriptor = -1;
		if (imagePath.length > 0) {
			[self openImageAtPath:imagePath readOnly:readOnly];
		}
	}
	return self;
}

- (void)dealloc {
	if (_descriptor >= 0) {
		close(_descriptor);
	}
}

- (void)openImageAtPath:(NSString *)path readOnly:(BOOL)readOnly {
	int descriptor = open(path.fileSystemRepresentation, readOnly ? O_RDONLY : O_RDWR);
	if (descriptor < 0 && !readOnly) {
		descriptor = open(path.fileSystemRepresentation, O_RDONLY);
	}
	if (descriptor < 0) {
		[VLStartupLog log:@"virtio-blk 打不开镜像：%@", path.lastPathComponent];
		return;
	}

	struct stat info;
	if (fstat(descriptor, &info) != 0) {
		close(descriptor);
		return;
	}

	_descriptor = descriptor;
	_capacityInBytes = (uint64_t)info.st_size;
	[VLStartupLog log:@"virtio-blk 已挂载 %@（%llu MB%@）",
	 path.lastPathComponent,
	 (unsigned long long)(_capacityInBytes / (1024ULL * 1024ULL)),
	 _readOnly ? @"，只读" : @""];
}

#pragma mark - 设备描述

- (uint32_t)virtioDeviceID {
	return 2; // virtio-blk
}

- (uint32_t)virtioDeviceFeatures {
	return 1u << 9; // VIRTIO_BLK_F_FLUSH
}

- (uint32_t)queueNumMax {
	return VLBlockQueueNumMax;
}

- (uint32_t)readConfigAtOffset:(uint32_t)offset width:(uint32_t)width {
	uint8_t bytes[24];
	memset(bytes, 0, sizeof(bytes));

	uint64_t sectors = _capacityInBytes / VLBlockSectorSize;
	for (uint32_t index = 0; index < 8; index++) {
		bytes[index] = (uint8_t)((sectors >> (8 * index)) & 0xFF);
	}
	for (uint32_t index = 0; index < 4; index++) {
		bytes[8 + index] = (uint8_t)((VLBlockMaximumTransferSize >> (8 * index)) & 0xFF);
		bytes[12 + index] = (uint8_t)((VLBlockSectorSize >> (8 * index)) & 0xFF);
	}

	if ((uint64_t)offset + width > sizeof(bytes)) {
		return 0;
	}
	uint32_t value = 0;
	for (uint32_t index = 0; index < width; index++) {
		value |= (uint32_t)bytes[offset + index] << (8 * index);
	}
	return value;
}

#pragma mark - 请求

- (uint32_t)handleDescriptorChain:(NSArray<VLVirtioBufferDescriptor *> *)chain
							 head:(uint16_t)head
					   queueIndex:(uint32_t)queueIndex {
	if (chain.count < 2) {
		return 0;
	}

	VLVirtioBufferDescriptor *request = chain.firstObject;
	VLVirtioBufferDescriptor *status = chain.lastObject;
	if (request.length < 16 || status.length < 1 || !status.writable) {
		return 0;
	}

	const uint8_t *header = [self.guestMemory hostPointerForGuestAddress:request.address length:16];
	uint8_t *statusByte = [self.guestMemory hostPointerForGuestAddress:status.address length:1];
	if (header == NULL || statusByte == NULL) {
		return 0;
	}

	uint32_t type = VLBlockReadLE32(header);
	uint64_t sector = VLBlockReadLE64(header + 8);
	uint8_t result = VLBlockStatusOkay;

	if (_descriptor < 0) {
		result = VLBlockStatusIOError;
	} else if (type == VLBlockRequestFlush) {
		if (fsync(_descriptor) != 0) {
			result = VLBlockStatusIOError;
		}
	} else if (type == VLBlockRequestIn || type == VLBlockRequestOut) {
		result = [self transferChain:chain type:type offset:sector * VLBlockSectorSize];
	} else {
		result = VLBlockStatusUnsupported;
	}

	*statusByte = result;
	return 1;
}

- (uint8_t)transferChain:(NSArray<VLVirtioBufferDescriptor *> *)chain
					type:(uint32_t)type
				  offset:(uint64_t)offset {
	BOOL isWrite = type == VLBlockRequestOut;
	if (isWrite && _readOnly) {
		return VLBlockStatusIOError;
	}

	uint64_t total = 0;
	for (NSUInteger index = 1; index + 1 < chain.count; index++) {
		total += chain[index].length;
	}
	if (offset > _capacityInBytes || total > _capacityInBytes - offset) {
		return VLBlockStatusIOError;
	}

	uint64_t cursor = offset;
	for (NSUInteger index = 1; index + 1 < chain.count; index++) {
		VLVirtioBufferDescriptor *descriptor = chain[index];
		if (descriptor.length == 0) {
			continue;
		}
		uint8_t *pointer = [self.guestMemory hostPointerForGuestAddress:descriptor.address
																 length:descriptor.length];
		if (pointer == NULL) {
			return VLBlockStatusIOError;
		}
		ssize_t done = isWrite
			? pwrite(_descriptor, pointer, descriptor.length, (off_t)cursor)
			: pread(_descriptor, pointer, descriptor.length, (off_t)cursor);
		if (done != (ssize_t)descriptor.length) {
			return VLBlockStatusIOError;
		}
		cursor += descriptor.length;
	}
	return VLBlockStatusOkay;
}

@end
