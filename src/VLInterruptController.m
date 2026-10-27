#import "VLInterruptController.h"

#import <stdlib.h>

// 分发器寄存器偏移
static const uint32_t VLGICDistributorControl = 0x000;
static const uint32_t VLGICDistributorType = 0x004;
static const uint32_t VLGICDistributorEnableSet = 0x100;
static const uint32_t VLGICDistributorEnableClear = 0x180;
static const uint32_t VLGICDistributorPendingSet = 0x200;
static const uint32_t VLGICDistributorPendingClear = 0x280;
static const uint32_t VLGICDistributorActiveSet = 0x300;
static const uint32_t VLGICDistributorActiveClear = 0x380;
static const uint32_t VLGICDistributorPriority = 0x400;
static const uint32_t VLGICDistributorTargets = 0x800;
static const uint32_t VLGICDistributorSGIR = 0xF00;

// CPU 接口寄存器偏移（每核一份，8 KB）
static const uint32_t VLGICCPUControl = 0x000;
static const uint32_t VLGICCPUPMR = 0x004;
static const uint32_t VLGICCPUAcknowledge = 0x00C;
static const uint32_t VLGICCPUEndOfInterrupt = 0x010;
static const uint32_t VLGICCPURunningPriority = 0x014;
static const uint32_t VLGICCPUPending = 0x018;
static const uint32_t VLGICCPUIdentifier = 0x0FC;
static const uint32_t VLGICCPUDir = 0x1000;

static const uint32_t VLGICSpuriousIRQ = 1023;
static const uint32_t VLGICPrivateInterrupts = 32;
#define VLGIC_MAXIMUM_IRQ 64
/// 设备树里最多声明这么多个核，和 VLLinuxVirtualMachine 的上限保持一致。
#define VLGIC_MAXIMUM_CPUS 8

static __thread uint32_t VLProcessorIndex = 0;

uint32_t VLProcessorIndexForCurrentThread(void) {
	return VLProcessorIndex;
}

void VLSetProcessorIndexForCurrentThread(uint32_t index) {
	VLProcessorIndex = index;
}

static uint32_t VLReadRegister(const uint8_t *registers, uint32_t offset, uint32_t width) {
	uint32_t value = 0;
	for (uint32_t index = 0; index < width; index++) {
		value |= (uint32_t)registers[offset + index] << (8 * index);
	}
	return value;
}

static void VLWriteRegister(uint8_t *registers, uint32_t offset, uint32_t width, uint32_t value) {
	for (uint32_t index = 0; index < width; index++) {
		registers[offset + index] = (uint8_t)((value >> (8 * index)) & 0xFF);
	}
}

@implementation VLInterruptController {
	uint8_t *_distributor;
	/// 每个核 8 KB 的 CPU 接口窗口，按核序号排开。
	uint8_t *_cpuInterfaces;
	/// SPI（32 起）在分发器上的挂起状态。
	BOOL _pending[VLGIC_MAXIMUM_IRQ];
	/// SGI / PPI 是核私有的，每个核一份（前 32 项）。
	BOOL *_privatePending;
	/// active 也是核私有的。
	BOOL *_active;
	BOOL _enabled[VLGIC_MAXIMUM_IRQ];
	/// SPI 的目标核位图（GICD_ITARGETSR）。
	uint8_t _targets[VLGIC_MAXIMUM_IRQ];
	BOOL _lineAsserted[VLGIC_MAXIMUM_CPUS];
	NSUInteger _cpuCount;
}

- (instancetype)initWithBaseAddress:(uint64_t)baseAddress cpuCount:(NSUInteger)cpuCount {
	self = [super init];
	if (self) {
		_baseAddress = baseAddress;
		_cpuCount = MAX((NSUInteger)1, MIN(cpuCount, (NSUInteger)VLGIC_MAXIMUM_CPUS));
		_regionSize = 0x1000 + (uint32_t)_cpuCount * 0x2000;
		_distributor = calloc(1, 0x1000);
		_cpuInterfaces = calloc(_cpuCount, 0x2000);
		_privatePending = calloc(_cpuCount, VLGICPrivateInterrupts * sizeof(BOOL));
		_active = calloc(_cpuCount, VLGIC_MAXIMUM_IRQ * sizeof(BOOL));
		// 复位值：优先级全 0xA0，PMR 允许全部优先级，SPI 默认目标核是 0 号核。
		for (uint32_t index = 0; index < VLGIC_MAXIMUM_IRQ; index++) {
			_distributor[VLGICDistributorPriority + index] = 0xA0;
			// 复位后 SPI 都指向 0 号核，Linux 会在 gic_dist_init 里重写。
			_targets[index] = 0x01;
		}
		for (NSUInteger cpu = 0; cpu < _cpuCount; cpu++) {
			_cpuInterfaces[cpu * 0x2000 + VLGICCPUPMR] = 0xF0;
		}
	}
	return self;
}

- (void)dealloc {
	free(_distributor);
	free(_cpuInterfaces);
	free(_privatePending);
	free(_active);
}

- (uint32_t)currentCPU {
	uint32_t cpu = VLProcessorIndex;
	return cpu < _cpuCount ? cpu : 0;
}

#pragma mark - 挂起状态

- (BOOL)isInterruptPending:(uint32_t)irq forCPU:(uint32_t)cpu {
	if (irq < VLGICPrivateInterrupts) {
		return _privatePending[cpu * VLGICPrivateInterrupts + irq];
	}
	if (!_pending[irq]) {
		return NO;
	}
	// SPI 只投递给目标核，没指向这个核就看不见。
	return (_targets[irq] & (1u << cpu)) != 0;
}

- (void)setInterrupt:(uint32_t)irq pending:(BOOL)pending forCPU:(uint32_t)cpu {
	if (irq < VLGICPrivateInterrupts) {
		_privatePending[cpu * VLGICPrivateInterrupts + irq] = pending;
		if (pending) {
			_distributor[VLGICDistributorPendingSet + irq / 8] |= (uint8_t)(1u << (irq % 8));
		}
		return;
	}
	_pending[irq] = pending;
	if (pending) {
		_distributor[VLGICDistributorPendingSet + irq / 8] |= (uint8_t)(1u << (irq % 8));
	} else {
		_distributor[VLGICDistributorPendingSet + irq / 8] &= (uint8_t)~(1u << (irq % 8));
	}
}

- (BOOL)canDeliverInterrupt:(uint32_t)irq toCPU:(uint32_t)cpu {
	if (!_enabled[irq] || _active[cpu * VLGIC_MAXIMUM_IRQ + irq]) {
		return NO;
	}
	if (![self isInterruptPending:irq forCPU:cpu]) {
		return NO;
	}
	uint8_t pmr = _cpuInterfaces[cpu * 0x2000 + VLGICCPUPMR];
	return _distributor[VLGICDistributorPriority + irq] < pmr;
}

- (uint32_t)highestPendingInterruptForCPU:(uint32_t)cpu {
	uint32_t best = VLGICSpuriousIRQ;
	uint8_t bestPriority = 0xFF;
	for (uint32_t irq = 0; irq < VLGIC_MAXIMUM_IRQ; irq++) {
		if (![self canDeliverInterrupt:irq toCPU:cpu]) {
			continue;
		}
		uint8_t priority = _distributor[VLGICDistributorPriority + irq];
		if (priority < bestPriority) {
			bestPriority = priority;
			best = irq;
		}
	}
	return best;
}

#pragma mark - 中断线

- (void)refreshLines {
	for (NSUInteger cpu = 0; cpu < _cpuCount; cpu++) {
		BOOL asserted = [self highestPendingInterruptForCPU:(uint32_t)cpu] != VLGICSpuriousIRQ;
		if (asserted == _lineAsserted[cpu]) {
			continue;
		}
		_lineAsserted[cpu] = asserted;
		if (self.irqLineHandler != nil) {
			self.irqLineHandler((uint32_t)cpu, asserted);
		}
	}
}

- (void)setIRQPending:(uint32_t)irq {
	if (irq >= VLGIC_MAXIMUM_IRQ) {
		return;
	}
	[self setInterrupt:irq pending:YES forCPU:[self currentCPU]];
	[self refreshLines];
}

- (void)clearIRQPending:(uint32_t)irq {
	if (irq >= VLGIC_MAXIMUM_IRQ) {
		return;
	}
	[self setInterrupt:irq pending:NO forCPU:[self currentCPU]];
	[self refreshLines];
}

#pragma mark - 读

- (uint32_t)readAtOffset:(uint32_t)offset width:(uint32_t)width {
	if (offset < 0x1000) {
		return [self readDistributorAtOffset:offset width:width];
	}
	if (offset < _regionSize) {
		uint32_t cpu = (offset - 0x1000) / 0x2000;
		uint32_t cpuOffset = (offset - 0x1000) % 0x2000;
		uint8_t *window = _cpuInterfaces + cpu * 0x2000;
		if (cpuOffset == VLGICCPUAcknowledge) {
			return [self acknowledgeInterruptForCPU:cpu];
		}
		if (cpuOffset == VLGICCPUPending) {
			return [self highestPendingInterruptForCPU:cpu];
		}
		if (cpuOffset == VLGICCPURunningPriority) {
			return 0xFF;
		}
		if (cpuOffset == VLGICCPUIdentifier) {
			return 0x0102043B;
		}
		if (cpuOffset == VLGICCPUDir) {
			// DIR 只是身份寄存器，读到 0 即可。
			return 0;
		}
		return VLReadRegister(window, cpuOffset, width);
	}
	return 0;
}

- (uint32_t)readDistributorAtOffset:(uint32_t)offset width:(uint32_t)width {
	if (offset == VLGICDistributorType) {
		// ITLinesNumber = 1（共 64 个中断），CPUNumber = 核数 - 1。
		return 1 | (((uint32_t)_cpuCount - 1) << 5);
	}
	if (offset >= VLGICDistributorTargets && offset < VLGICDistributorTargets + 0x400) {
		// ITARGETSR 按字节存放每个中断的目标核；PPI / SGI 读出来就是「本核」。
		uint32_t value = 0;
		for (uint32_t index = 0; index < width; index++) {
			uint32_t irq = offset + index - VLGICDistributorTargets;
			uint8_t target = irq < VLGICPrivateInterrupts
				? (uint8_t)(1u << [self currentCPU])
				: _targets[irq];
			value |= (uint32_t)target << (8 * index);
		}
		return value;
	}
	return VLReadRegister(_distributor, offset, width);
}

- (uint32_t)acknowledgeInterruptForCPU:(uint32_t)cpu {
	uint32_t irq = [self highestPendingInterruptForCPU:cpu];
	if (irq == VLGICSpuriousIRQ) {
		return VLGICSpuriousIRQ;
	}
	[self setInterrupt:irq pending:NO forCPU:cpu];
	_active[cpu * VLGIC_MAXIMUM_IRQ + irq] = YES;
	// ack 之后中断线可能还有别的挂起中断，但要等这次 EOI 完再报，避免重复注入。
	[self refreshLines];
	return irq;
}

#pragma mark - 写

- (void)writeAtOffset:(uint32_t)offset width:(uint32_t)width value:(uint32_t)value {
	if (offset < 0x1000) {
		[self writeDistributorAtOffset:offset width:width value:value];
		return;
	}
	if (offset >= _regionSize) {
		return;
	}
	uint32_t cpu = (offset - 0x1000) / 0x2000;
	uint32_t cpuOffset = (offset - 0x1000) % 0x2000;
	uint8_t *window = _cpuInterfaces + cpu * 0x2000;

	if (cpuOffset == VLGICCPUEndOfInterrupt) {
		uint32_t irq = value & 0x3FF;
		if (irq < VLGIC_MAXIMUM_IRQ) {
			_active[cpu * VLGIC_MAXIMUM_IRQ + irq] = NO;
			[self refreshLines];
		}
		return;
	}
	if (cpuOffset == VLGICCPUDir) {
		return;
	}
	VLWriteRegister(window, cpuOffset, width, value);
	if (cpuOffset == VLGICCPUPMR || cpuOffset == VLGICCPUControl) {
		[self refreshLines];
	}
}

- (void)writeDistributorAtOffset:(uint32_t)offset width:(uint32_t)width value:(uint32_t)value {
	// ISENABLER 这类寄存器写 1 才生效、读出来是当前状态，所以位图要和影子寄存器同步。
	if (offset >= VLGICDistributorEnableSet && offset < VLGICDistributorEnableSet + 0x20) {
		[self applyBitmapWrite:_enabled
				   setBaseOffset:VLGICDistributorEnableSet
				 clearBaseOffset:VLGICDistributorEnableClear
						offset:offset
						 value:value];
		VLWriteRegister(_distributor, offset, width, value);
		[self refreshLines];
		return;
	}
	if (offset >= VLGICDistributorEnableClear && offset < VLGICDistributorEnableClear + 0x20) {
		[self applyBitmapWrite:_enabled
				   setBaseOffset:VLGICDistributorEnableSet
				 clearBaseOffset:VLGICDistributorEnableClear
						offset:offset
						 value:value];
		VLWriteRegister(_distributor, offset, width, 0);
		[self refreshLines];
		return;
	}
	if (offset >= VLGICDistributorPendingSet && offset < VLGICDistributorPendingSet + 0x20) {
		uint32_t cpu = [self currentCPU];
		uint32_t wordIndex = (offset - VLGICDistributorPendingSet) / 4;
		for (uint32_t bit = 0; bit < 32; bit++) {
			uint32_t irq = wordIndex * 32 + bit;
			if ((value & (1u << bit)) != 0 && irq < VLGIC_MAXIMUM_IRQ) {
				[self setInterrupt:irq pending:YES forCPU:cpu];
			}
		}
		[self refreshLines];
		return;
	}
	if (offset >= VLGICDistributorPendingClear && offset < VLGICDistributorPendingClear + 0x20) {
		uint32_t cpu = [self currentCPU];
		uint32_t wordIndex = (offset - VLGICDistributorPendingClear) / 4;
		for (uint32_t bit = 0; bit < 32; bit++) {
			uint32_t irq = wordIndex * 32 + bit;
			if ((value & (1u << bit)) != 0 && irq < VLGIC_MAXIMUM_IRQ) {
				[self setInterrupt:irq pending:NO forCPU:cpu];
			}
		}
		[self refreshLines];
		return;
	}
	if (offset >= VLGICDistributorActiveSet && offset < VLGICDistributorActiveSet + 0x20) {
		uint32_t cpu = [self currentCPU];
		uint32_t wordIndex = (offset - VLGICDistributorActiveSet) / 4;
		for (uint32_t bit = 0; bit < 32; bit++) {
			uint32_t irq = wordIndex * 32 + bit;
			if ((value & (1u << bit)) != 0 && irq < VLGIC_MAXIMUM_IRQ) {
				_active[cpu * VLGIC_MAXIMUM_IRQ + irq] = YES;
			}
		}
		VLWriteRegister(_distributor, offset, width, value);
		[self refreshLines];
		return;
	}
	if (offset >= VLGICDistributorActiveClear && offset < VLGICDistributorActiveClear + 0x20) {
		uint32_t cpu = [self currentCPU];
		uint32_t wordIndex = (offset - VLGICDistributorActiveClear) / 4;
		for (uint32_t bit = 0; bit < 32; bit++) {
			uint32_t irq = wordIndex * 32 + bit;
			if ((value & (1u << bit)) != 0 && irq < VLGIC_MAXIMUM_IRQ) {
				_active[cpu * VLGIC_MAXIMUM_IRQ + irq] = NO;
			}
		}
		VLWriteRegister(_distributor, VLGICDistributorActiveSet + (offset - VLGICDistributorActiveClear),
						width, 0);
		[self refreshLines];
		return;
	}
	if (offset >= VLGICDistributorTargets && offset < VLGICDistributorTargets + 0x400) {
		[self writeTargetsAtOffset:offset width:width value:value];
		[self refreshLines];
		return;
	}
	if (offset == VLGICDistributorSGIR) {
		[self sendSoftwareGeneratedInterrupt:value];
		return;
	}

	VLWriteRegister(_distributor, offset, width, value);
	if (offset == VLGICDistributorControl) {
		[self refreshLines];
	}
}

/// 写 ITARGETSR：PPI / SGI 是核私有的、只读，SPI 更新目标核位图。
- (void)writeTargetsAtOffset:(uint32_t)offset width:(uint32_t)width value:(uint32_t)value {
	for (uint32_t index = 0; index < width; index++) {
		uint32_t irq = offset + index - VLGICDistributorTargets;
		if (irq < VLGICPrivateInterrupts || irq >= VLGIC_MAXIMUM_IRQ) {
			continue;
		}
		_targets[irq] = (uint8_t)((value >> (8 * index)) & 0xFF);
	}
	VLWriteRegister(_distributor, offset, width, value);
}

/// GICD_SGIR：核间中断（IPI）。Linux 的调度、TLB、唤醒都要靠它，缺了多核会卡住。
- (void)sendSoftwareGeneratedInterrupt:(uint32_t)value {
	uint32_t irq = value & 0xF;
	uint32_t targetList = (value >> 16) & 0xFF;
	uint32_t filter = (value >> 24) & 0x3;
	uint32_t requestingCPU = [self currentCPU];

	for (NSUInteger cpu = 0; cpu < _cpuCount; cpu++) {
		BOOL targeted = NO;
		switch (filter) {
			case 0:
				targeted = ((targetList >> cpu) & 0x1) != 0;
				break;
			case 1:
				targeted = cpu != requestingCPU;
				break;
			case 2:
				targeted = cpu == requestingCPU;
				break;
			default:
				break;
		}
		if (targeted) {
			_privatePending[cpu * VLGICPrivateInterrupts + irq] = YES;
		}
	}
	_distributor[VLGICDistributorPendingSet + irq / 8] |= (uint8_t)(1u << (irq % 8));
	[self refreshLines];
}

- (void)applyBitmapWrite:(BOOL *)bitmap
		   setBaseOffset:(uint32_t)setBase
		 clearBaseOffset:(uint32_t)clearBase
				  offset:(uint32_t)offset
				   value:(uint32_t)value {
	BOOL enabling = offset < clearBase;
	uint32_t relative = enabling ? offset - setBase : offset - clearBase;
	uint32_t wordIndex = relative / 4;
	for (uint32_t bit = 0; bit < 32; bit++) {
		uint32_t irq = wordIndex * 32 + bit;
		if (irq >= VLGIC_MAXIMUM_IRQ) {
			break;
		}
		if ((value & (1u << bit)) == 0) {
			continue;
		}
		bitmap[irq] = enabling;
	}
}

@end
