#import "VLDeviceBus.h"

@implementation VLDeviceBus {
	NSMutableArray<id<VLDevice>> *_devices;
}

- (instancetype)init {
	self = [super init];
	if (self) {
		_devices = [NSMutableArray array];
	}
	return self;
}

- (void)addDevice:(id<VLDevice>)device {
	if (device != nil) {
		[_devices addObject:device];
	}
}

- (id<VLDevice>)deviceForAddress:(uint64_t)address offset:(uint32_t *)offset {
	for (id<VLDevice> device in _devices) {
		uint64_t base = device.baseAddress;
		uint32_t size = device.regionSize;
		if (address >= base && address - base < size) {
			if (offset != NULL) {
				*offset = (uint32_t)(address - base);
			}
			return device;
		}
	}
	return nil;
}

- (BOOL)readAddress:(uint64_t)address width:(uint32_t)width value:(uint32_t *)value {
	uint32_t offset = 0;
	id<VLDevice> device = [self deviceForAddress:address offset:&offset];
	if (device == nil) {
		return NO;
	}
	uint32_t result = [device readAtOffset:offset width:width];
	if (value != NULL) {
		*value = result;
	}
	return YES;
}

- (BOOL)writeAddress:(uint64_t)address width:(uint32_t)width value:(uint32_t)value {
	uint32_t offset = 0;
	id<VLDevice> device = [self deviceForAddress:address offset:&offset];
	if (device == nil) {
		return NO;
	}
	[device writeAtOffset:offset width:width value:value];
	return YES;
}

@end
