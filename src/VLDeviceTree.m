#import "VLDeviceTree.h"

#import <string.h>

static const uint32_t VLFDTMagic = 0xD00DFEED;
static const uint32_t VLFDTVersion = 17;
static const uint32_t VLFDTLastCompatibleVersion = 16;

static const uint32_t VLFDTTokenBeginNode = 1;
static const uint32_t VLFDTTokenEndNode = 2;
static const uint32_t VLFDTTokenProperty = 3;
static const uint32_t VLFDTTokenEnd = 9;

static const uint32_t VLFDTPHandleInterruptController = 1;

static const NSUInteger VLFDTMaximumCPUs = 8;

static void VLAppendBE32(NSMutableData *data, uint32_t value) {
	uint8_t bytes[4] = {
		(uint8_t)((value >> 24) & 0xFF),
		(uint8_t)((value >> 16) & 0xFF),
		(uint8_t)((value >> 8) & 0xFF),
		(uint8_t)(value & 0xFF),
	};
	[data appendBytes:bytes length:4];
}

static void VLAppendBE64(NSMutableData *data, uint64_t value) {
	VLAppendBE32(data, (uint32_t)(value >> 32));
	VLAppendBE32(data, (uint32_t)(value & 0xFFFFFFFF));
}

@implementation VLDeviceTree {
	NSMutableData *_structure;
	NSMutableData *_strings;
	NSMutableDictionary<NSString *, NSNumber *> *_stringOffsets;
}

+ (NSData *)deviceTreeWithMemoryBase:(uint64_t)memoryBase
						  memorySize:(uint64_t)memorySize
					   bootArguments:(NSString *)bootArguments
						 initrdStart:(uint64_t)initrdStart
						   initrdEnd:(uint64_t)initrdEnd
						   cpuCount:(NSUInteger)cpuCount
							uartBase:(uint64_t)uartBase
							 gicBase:(uint64_t)gicBase
							 gpuBase:(uint64_t)gpuBase
						   blockBase:(uint64_t)blockBase
							 isoBase:(uint64_t)isoBase
						   inputBase:(uint64_t)inputBase
							 netBase:(uint64_t)netBase
						hasBlockDisk:(BOOL)hasBlockDisk
						   hasISODisc:(BOOL)hasISODisc {
	VLDeviceTree *builder = [[VLDeviceTree alloc] init];
	return [builder buildWithMemoryBase:memoryBase
							 memorySize:memorySize
						  bootArguments:bootArguments
							initrdStart:initrdStart
							  initrdEnd:initrdEnd
							   cpuCount:cpuCount
							   uartBase:uartBase
								gicBase:gicBase
								gpuBase:gpuBase
							  blockBase:blockBase
								isoBase:isoBase
							  inputBase:inputBase
								netBase:netBase
						   hasBlockDisk:hasBlockDisk
							  hasISODisc:hasISODisc];
}

- (instancetype)init {
	self = [super init];
	if (self) {
		_structure = [NSMutableData data];
		_strings = [NSMutableData data];
		_stringOffsets = [NSMutableDictionary dictionary];
	}
	return self;
}

#pragma mark - 组包

- (NSData *)buildWithMemoryBase:(uint64_t)memoryBase
					 memorySize:(uint64_t)memorySize
				  bootArguments:(NSString *)bootArguments
					initrdStart:(uint64_t)initrdStart
					  initrdEnd:(uint64_t)initrdEnd
					   cpuCount:(NSUInteger)cpuCount
					   uartBase:(uint64_t)uartBase
						gicBase:(uint64_t)gicBase
						gpuBase:(uint64_t)gpuBase
					  blockBase:(uint64_t)blockBase
						isoBase:(uint64_t)isoBase
					  inputBase:(uint64_t)inputBase
						netBase:(uint64_t)netBase
				   hasBlockDisk:(BOOL)hasBlockDisk
					  hasISODisc:(BOOL)hasISODisc {
	NSUInteger cores = MAX((NSUInteger)1, MIN(cpuCount, VLFDTMaximumCPUs));

	[self beginNode:@""];

	[self propertyNamed:@"compatible" string:@"linux,dummy-virt"];
	[self propertyNamed:@"#address-cells" cells:@[ @2 ]];
	[self propertyNamed:@"#size-cells" cells:@[ @2 ]];
	[self propertyNamed:@"interrupt-parent" cells:@[ @(VLFDTPHandleInterruptController) ]];

	// chosen：内核参数与 initrd 位置
	[self beginNode:@"chosen"];
	[self propertyNamed:@"bootargs" string:bootArguments ?: @""];
	[self propertyNamed:@"stdout-path"
				 string:[NSString stringWithFormat:@"serial@%llx", (unsigned long long)uartBase]];
	[self propertyNamed:@"linux,initrd-start" u64:initrdStart];
	[self propertyNamed:@"linux,initrd-end" u64:initrdEnd];
	[self endNode];

	// memory
	[self beginNode:[NSString stringWithFormat:@"memory@%llx", (unsigned long long)memoryBase]];
	[self propertyNamed:@"device_type" string:@"memory"];
	[self propertyNamed:@"reg"
				   cells:@[
					   @((uint32_t)(memoryBase >> 32)), @((uint32_t)(memoryBase & 0xFFFFFFFF)),
					   @((uint32_t)(memorySize >> 32)), @((uint32_t)(memorySize & 0xFFFFFFFF)),
				   ]];
	[self endNode];

	// cpus：每个核一个节点，reg 就是 MPIDR，PSCI 的 CPU_ON 按这个值找核
	[self beginNode:@"cpus"];
	[self propertyNamed:@"#address-cells" cells:@[ @1 ]];
	[self propertyNamed:@"#size-cells" cells:@[ @0 ]];
	for (NSUInteger core = 0; core < cores; core++) {
		[self beginNode:[NSString stringWithFormat:@"cpu@%lu", (unsigned long)core]];
		[self propertyNamed:@"device_type" string:@"cpu"];
		[self propertyNamed:@"reg" cells:@[ @(core) ]];
		[self propertyNamed:@"compatible" string:@"arm,cortex-a57"];
		[self propertyNamed:@"enable-method" string:@"psci"];
		[self endNode];
	}
	[self endNode];

	// PSCI：开机、关机、重启都走 HVC
	[self beginNode:@"psci"];
	[self propertyNamed:@"compatible" string:@"arm,psci-1.0"];
	[self propertyNamed:@"method" string:@"hvc"];
	[self endNode];

	// 定时器：4 个 PPI（安全物理、非安全物理、虚拟、非安全虚拟）
	[self beginNode:@"timer"];
	[self propertyNamed:@"compatible" string:@"arm,armv8-timer"];
	[self propertyNamed:@"interrupts"
				   cells:@[ @1, @13, @0xF08, @1, @14, @0xF08, @1, @11, @0xF08, @1, @10, @0xF08 ]];
	[self propertyNamed:@"always-on" bytes:[NSData data]];
	[self endNode];

	// GICv2：分发器 4 KB + CPU 接口 8 KB。CPU 接口是各核共用的同一个地址窗口
	// （寄存器按核 banking），所以这里固定 0x2000，与核数无关。
	[self beginNode:[NSString stringWithFormat:@"interrupt-controller@%llx", (unsigned long long)gicBase]];
	[self propertyNamed:@"compatible" string:@"arm,cortex-a15-gic"];
	[self propertyNamed:@"#interrupt-cells" cells:@[ @3 ]];
	[self propertyNamed:@"interrupt-controller" bytes:[NSData data]];
	// 注意：#size-cells = 2，大小是「高 32 位、低 32 位」两个 cell。
	// 之前写成 @0x1000, @0 等于 0x1000_00000000（17 TB），ioremap 会把页表铺满整块内存。
	[self propertyNamed:@"reg"
				   cells:@[
					   @((uint32_t)(gicBase >> 32)), @((uint32_t)(gicBase & 0xFFFFFFFF)), @0, @0x1000,
					   @((uint32_t)((gicBase + 0x1000) >> 32)), @((uint32_t)((gicBase + 0x1000) & 0xFFFFFFFF)),
					   @0, @0x2000,
				   ]];
	[self propertyNamed:@"phandle" cells:@[ @(VLFDTPHandleInterruptController) ]];
	[self endNode];

	// 串口：SPI 1。compatible 必须带上 "arm,primecell"：内核才会按 amba 总线
	// 建这个设备并让 pl011 驱动匹配；只写 "arm,pl011" 会被当成普通平台设备，
	// 永远等不到 probe，ttyAMA0 不注册，用户态连控制台都打不开。
	[self beginNode:[NSString stringWithFormat:@"serial@%llx", (unsigned long long)uartBase]];
	[self propertyNamed:@"compatible" strings:@[ @"arm,pl011", @"arm,primecell" ]];
	[self propertyNamed:@"reg"
				   cells:@[
					   @((uint32_t)(uartBase >> 32)), @((uint32_t)(uartBase & 0xFFFFFFFF)), @0, @0x1000,
				   ]];
	[self propertyNamed:@"interrupts" cells:@[ @0, @1, @4 ]];
	[self propertyNamed:@"clock-frequency" cells:@[ @24000000 ]];
	[self endNode];

	// virtio-gpu：SPI 2
	[self beginNode:[NSString stringWithFormat:@"virtio_mmio@%llx", (unsigned long long)gpuBase]];
	[self propertyNamed:@"compatible" string:@"virtio,mmio"];
	[self propertyNamed:@"reg"
				   cells:@[
					   @((uint32_t)(gpuBase >> 32)), @((uint32_t)(gpuBase & 0xFFFFFFFF)), @0, @0x1000,
				   ]];
	[self propertyNamed:@"interrupts" cells:@[ @0, @2, @4 ]];
	[self endNode];

	// virtio-blk：SPI 3（没挂系统盘就不声明，否则内核探测会撞空地址）
	if (hasBlockDisk) {
		[self beginNode:[NSString stringWithFormat:@"virtio_mmio@%llx", (unsigned long long)blockBase]];
		[self propertyNamed:@"compatible" string:@"virtio,mmio"];
		[self propertyNamed:@"reg"
					   cells:@[
						   @((uint32_t)(blockBase >> 32)), @((uint32_t)(blockBase & 0xFFFFFFFF)), @0, @0x1000,
					   ]];
		[self propertyNamed:@"interrupts" cells:@[ @0, @3, @4 ]];
		[self endNode];
	}

	// virtio-input：SPI 4
	[self beginNode:[NSString stringWithFormat:@"virtio_mmio@%llx", (unsigned long long)inputBase]];
	[self propertyNamed:@"compatible" string:@"virtio,mmio"];
	[self propertyNamed:@"reg"
				   cells:@[
					   @((uint32_t)(inputBase >> 32)), @((uint32_t)(inputBase & 0xFFFFFFFF)), @0, @0x1000,
				   ]];
	[self propertyNamed:@"interrupts" cells:@[ @0, @4, @4 ]];
	[self endNode];

	// virtio-net：SPI 5
	[self beginNode:[NSString stringWithFormat:@"virtio_mmio@%llx", (unsigned long long)netBase]];
	[self propertyNamed:@"compatible" string:@"virtio,mmio"];
	[self propertyNamed:@"reg"
				   cells:@[
					   @((uint32_t)(netBase >> 32)), @((uint32_t)(netBase & 0xFFFFFFFF)), @0, @0x1000,
				   ]];
	[self propertyNamed:@"interrupts" cells:@[ @0, @5, @4 ]];
	[self endNode];

	// 安装镜像（只读光驱）：SPI 6（没选 ISO 就不声明）
	if (hasISODisc) {
		[self beginNode:[NSString stringWithFormat:@"virtio_mmio@%llx", (unsigned long long)isoBase]];
		[self propertyNamed:@"compatible" string:@"virtio,mmio"];
		[self propertyNamed:@"reg"
					   cells:@[
						   @((uint32_t)(isoBase >> 32)), @((uint32_t)(isoBase & 0xFFFFFFFF)), @0, @0x1000,
					   ]];
		[self propertyNamed:@"interrupts" cells:@[ @0, @6, @4 ]];
		[self endNode];
	}

	[self endNode];
	[self appendToken:VLFDTTokenEnd];

	return [self assembleBlob];
}

- (NSData *)assembleBlob {
	uint32_t structSize = (uint32_t)_structure.length;
	uint32_t stringsSize = (uint32_t)_strings.length;
	uint32_t structureOffset = 40 + 16; // 头部 + 空的内存保留表
	uint32_t stringsOffset = structureOffset + structSize;
	uint32_t totalSize = stringsOffset + stringsSize;

	NSMutableData *blob = [NSMutableData dataWithCapacity:totalSize];
	VLAppendBE32(blob, VLFDTMagic);
	VLAppendBE32(blob, totalSize);
	VLAppendBE32(blob, structureOffset);
	VLAppendBE32(blob, stringsOffset);
	VLAppendBE32(blob, 40);
	VLAppendBE32(blob, VLFDTVersion);
	VLAppendBE32(blob, VLFDTLastCompatibleVersion);
	VLAppendBE32(blob, 0);            // boot_cpuid_phys
	VLAppendBE32(blob, stringsSize);
	VLAppendBE32(blob, structSize);
	// 内存保留表：一项全 0 表示结束。
	uint8_t emptyReservation[16] = { 0 };
	[blob appendBytes:emptyReservation length:16];
	[blob appendData:_structure];
	[blob appendData:_strings];
	return blob;
}

#pragma mark - 结构块

- (void)appendToken:(uint32_t)token {
	VLAppendBE32(_structure, token);
}

- (void)padStructureToWord {
	while ((_structure.length % 4) != 0) {
		uint8_t zero = 0;
		[_structure appendBytes:&zero length:1];
	}
}

- (void)beginNode:(NSString *)nodeName {
	[self appendToken:VLFDTTokenBeginNode];
	NSData *name = [nodeName dataUsingEncoding:NSUTF8StringEncoding];
	[_structure appendData:name];
	uint8_t terminator = 0;
	[_structure appendBytes:&terminator length:1];
	[self padStructureToWord];
}

- (void)endNode {
	[self appendToken:VLFDTTokenEndNode];
}

- (uint32_t)offsetForString:(NSString *)name {
	NSNumber *cached = _stringOffsets[name];
	if (cached != nil) {
		return cached.unsignedIntValue;
	}
	uint32_t offset = (uint32_t)_strings.length;
	[_strings appendData:[name dataUsingEncoding:NSUTF8StringEncoding]];
	uint8_t terminator = 0;
	[_strings appendBytes:&terminator length:1];
	_stringOffsets[name] = @(offset);
	return offset;
}

- (void)propertyNamed:(NSString *)name bytes:(NSData *)data {
	[self appendToken:VLFDTTokenProperty];
	VLAppendBE32(_structure, (uint32_t)data.length);
	VLAppendBE32(_structure, [self offsetForString:name]);
	[_structure appendData:data];
	[self padStructureToWord];
}

- (void)propertyNamed:(NSString *)name string:(NSString *)value {
	NSData *encoded = [value dataUsingEncoding:NSUTF8StringEncoding];
	NSMutableData *data = [NSMutableData dataWithData:encoded];
	uint8_t terminator = 0;
	[data appendBytes:&terminator length:1];
	[self propertyNamed:name bytes:data];
}

- (void)propertyNamed:(NSString *)name strings:(NSArray<NSString *> *)values {
	// 多串 compatible：每个串各自以 NUL 结尾，拼成一段数据。
	NSMutableData *data = [NSMutableData data];
	for (NSString *value in values) {
		[data appendData:[value dataUsingEncoding:NSUTF8StringEncoding]];
		uint8_t terminator = 0;
		[data appendBytes:&terminator length:1];
	}
	[self propertyNamed:name bytes:data];
}

- (void)propertyNamed:(NSString *)name cells:(NSArray<NSNumber *> *)cells {
	NSMutableData *data = [NSMutableData dataWithCapacity:cells.count * 4];
	for (NSNumber *cell in cells) {
		VLAppendBE32(data, cell.unsignedIntValue);
	}
	[self propertyNamed:name bytes:data];
}

- (void)propertyNamed:(NSString *)name u64:(uint64_t)value {
	NSMutableData *data = [NSMutableData dataWithCapacity:8];
	VLAppendBE64(data, value);
	[self propertyNamed:name bytes:data];
}

@end
