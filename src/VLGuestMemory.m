#import "VLGuestMemory.h"

#import <string.h>
#import <sys/mman.h>
#import <unistd.h>

#import "VLHypervisor.h"

@implementation VLGuestMemory {
	void *_mapping;
	BOOL _mappedInGuest;
}

- (instancetype)initWithSize:(size_t)size guestAddress:(uint64_t)guestAddress {
	self = [super init];
	if (self) {
		// 页粒度对齐：Hypervisor 只接受整页映射。
		size_t pageSize = (size_t)getpagesize();
		uint64_t alignedAddress = guestAddress & ~((uint64_t)pageSize - 1);
		size_t alignedSize = (size + pageSize - 1) & ~(pageSize - 1);
		_guestAddress = alignedAddress;
		_size = alignedSize;
		_hostPointer = NULL;
		_mapping = NULL;
		_mappedInGuest = NO;
	}
	return self;
}

- (BOOL)allocateWithError:(NSError **)error {
	if (_hostPointer != NULL) {
		return YES;
	}

	void *memory = mmap(NULL, self.size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
	if (memory == MAP_FAILED) {
		if (error != NULL) {
			*error = [NSError errorWithDomain:@"VirtualLinux.Memory"
										 code:1
									 userInfo:@{ NSLocalizedDescriptionKey : @"客户机内存分配失败" }];
		}
		return NO;
	}

	VLHypervisor *hypervisor = VLHypervisor.shared;
	if (!hypervisor.available) {
		munmap(memory, self.size);
		if (error != NULL) {
			*error = [NSError errorWithDomain:@"VirtualLinux.Memory"
										 code:2
									 userInfo:@{ NSLocalizedDescriptionKey : hypervisor.failureReason ?: @"Hypervisor 不可用" }];
		}
		return NO;
	}

	// 内核镜像和数据都要可写可执行。
	int32_t result = [hypervisor mapHostPointer:memory
								   guestAddress:self.guestAddress
										   size:self.size
										  flags:VLHypervisorMemoryRead | VLHypervisorMemoryWrite | VLHypervisorMemoryExecute];
	if (result != 0) {
		munmap(memory, self.size);
		if (error != NULL) {
			*error = [NSError errorWithDomain:@"VirtualLinux.Memory"
										 code:3
									 userInfo:@{ NSLocalizedDescriptionKey :
										 [NSString stringWithFormat:@"客户机内存映射失败（hv_vm_map 返回 0x%x）", (unsigned)result] }];
		}
		return NO;
	}

	_mapping = memory;
	_hostPointer = memory;
	_mappedInGuest = YES;
	return YES;
}

- (void)deallocate {
	if (_mappedInGuest) {
		[VLHypervisor.shared unmapGuestAddress:self.guestAddress size:self.size];
		_mappedInGuest = NO;
	}
	if (_mapping != NULL) {
		munmap(_mapping, self.size);
		_mapping = NULL;
	}
	_hostPointer = NULL;
}

- (void *)hostPointerForGuestAddress:(uint64_t)guestAddress length:(size_t)length {
	if (self.hostPointer == NULL) {
		return NULL;
	}
	if (guestAddress < self.guestAddress) {
		return NULL;
	}
	uint64_t offset = guestAddress - self.guestAddress;
	if (offset > self.size || length > self.size - (size_t)offset) {
		return NULL;
	}
	return (uint8_t *)self.hostPointer + offset;
}

- (BOOL)writeData:(NSData *)data atGuestAddress:(uint64_t)guestAddress {
	if (data.length == 0) {
		return YES;
	}
	void *destination = [self hostPointerForGuestAddress:guestAddress length:data.length];
	if (destination == NULL) {
		return NO;
	}
	memcpy(destination, data.bytes, data.length);
	return YES;
}

- (NSInteger)loadFileAtPath:(NSString *)path atGuestAddress:(uint64_t)guestAddress {
	NSData *contents = [NSData dataWithContentsOfFile:path options:0 error:NULL];
	if (contents == nil) {
		return -1;
	}
	if (![self writeData:contents atGuestAddress:guestAddress]) {
		return -1;
	}
	return (NSInteger)contents.length;
}

@end
