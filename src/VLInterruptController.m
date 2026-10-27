#import "VLInterruptController.h"

#import <stdlib.h>

// 分发器寄存器偏移
static const uint32_t VLGICDistributorControl = 0x000;
static const uint32_t VLGICDistributorEnableSet = 0x100;
static const uint32_t VLGICDistributorEnableClear = 0x180;
static const uint32_t VLGICDistributorPendingSet = 0x200;
static const uint32_t VLGICDistributorPendingClear = 0x280;
static const uint32_t VLGICDistributorActiveSet = 0x300;
static const uint32_t VLGICDistributorActiveClear = 0x380;
static const uint32_t VLGICDistributorPriority = 0x400;

// CPU 接口寄存器偏移（相对 0x08001000）
static const uint32_t VLGICCPUControl = 0x000;
static const uint32_t VLGICCPUPMR = 0x004;
static const uint32_t VLGICCPUAcknowledge = 0x00C;
static const uint32_t VLGICCPUEndOfInterrupt = 0x010;
static const uint32_t VLGICCPURunningPriority = 0x014;
static const uint32_t VLGICCPUPending = 0x018;
static const uint32_t VLGICCPUIdentifier = 0x0FC;
static const uint32_t VLGICCPUDir = 0x1000;

static const uint32_t VLGICSpuriousIRQ = 1023;
#define VLGIC_MAXIMUM_IRQ 64

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
	uint8_t *_cpuInterface;
	BOOL _enabled[VLGIC_MAXIMUM_IRQ];
	BOOL _pending[VLGIC_MAXIMUM_IRQ];
	BOOL _active[VLGIC_MAXIMUM_IRQ];
	BOOL _lineAsserted;
}

- (instancetype)initWithBaseAddress:(uint64_t)baseAddress {
	self = [super init];
	if (self) {
		_baseAddress = baseAddress;
		_regionSize = 0x3000;
		_distributor = calloc(1, 0x1000);
		_cpuInterface = calloc(1, 0x2000);
		// 复位值：优先级全 0xA0，PMR 允许全部优先级。
		for (uint32_t index = 0; index < VLGIC_MAXIMUM_IRQ; index++) {
			_distributor[VLGICDistributorPriority + index] = 0xA0;
		}
	}
	return self;
}

- (void)dealloc {
	free(_distributor);
	free(_cpuInterface);
}

#pragma mark - 中断线

- (BOOL)hasPendingInterrupt {
	uint8_t pmr = _cpuInterface[VLGICCPUPMR];
	for (uint32_t irq = 0; irq < VLGIC_MAXIMUM_IRQ; irq++) {
		if (_enabled[irq] && _pending[irq] && !_active[irq]) {
			uint8_t priority = _distributor[VLGICDistributorPriority + irq];
			if (priority < pmr) {
				return YES;
			}
		}
	}
	return NO;
}

- (void)refreshLine {
	BOOL asserted = [self hasPendingInterrupt];
	if (asserted == _lineAsserted) {
		return;
	}
	_lineAsserted = asserted;
	if (self.irqLineHandler != nil) {
		self.irqLineHandler(asserted);
	}
}

- (void)setIRQPending:(uint32_t)irq {
	if (irq >= VLGIC_MAXIMUM_IRQ) {
		return;
	}
	_pending[irq] = YES;
	_distributor[VLGICDistributorPendingSet + irq / 8] |= (uint8_t)(1u << (irq % 8));
	[self refreshLine];
}

- (void)clearIRQPending:(uint32_t)irq {
	if (irq >= VLGIC_MAXIMUM_IRQ) {
		return;
	}
	_pending[irq] = NO;
	_distributor[VLGICDistributorPendingSet + irq / 8] &= (uint8_t)~(1u << (irq % 8));
	[self refreshLine];
}

#pragma mark - 读

- (uint32_t)readAtOffset:(uint32_t)offset width:(uint32_t)width {
	if (offset < 0x1000) {
		return VLReadRegister(_distributor, offset, width);
	}
	if (offset >= 0x1000 && offset < 0x3000) {
		uint32_t cpuOffset = offset - 0x1000;
		if (cpuOffset == VLGICCPUAcknowledge) {
			return [self acknowledgeInterrupt];
		}
		if (cpuOffset == VLGICCPUPending) {
			return [self highestPendingInterrupt];
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
		return VLReadRegister(_cpuInterface, cpuOffset, width);
	}
	return 0;
}

- (uint32_t)highestPendingInterrupt {
	uint8_t pmr = _cpuInterface[VLGICCPUPMR];
	uint32_t best = VLGICSpuriousIRQ;
	uint8_t bestPriority = 0xFF;
	for (uint32_t irq = 0; irq < VLGIC_MAXIMUM_IRQ; irq++) {
		if (!_enabled[irq] || !_pending[irq]) {
			continue;
		}
		uint8_t priority = _distributor[VLGICDistributorPriority + irq];
		if (priority >= pmr) {
			continue;
		}
		if (priority < bestPriority) {
			bestPriority = priority;
			best = irq;
		}
	}
	return best;
}

- (uint32_t)acknowledgeInterrupt {
	uint32_t irq = [self highestPendingInterrupt];
	if (irq == VLGICSpuriousIRQ) {
		return VLGICSpuriousIRQ;
	}
	_pending[irq] = NO;
	_active[irq] = YES;
	_distributor[VLGICDistributorPendingSet + irq / 8] &= (uint8_t)~(1u << (irq % 8));
	[self refreshLine];
	return irq;
}

#pragma mark - 写

- (void)writeAtOffset:(uint32_t)offset width:(uint32_t)width value:(uint32_t)value {
	if (offset < 0x1000) {
		[self writeDistributorAtOffset:offset width:width value:value];
		return;
	}
	if (offset >= 0x1000 && offset < 0x3000) {
		uint32_t cpuOffset = offset - 0x1000;
		if (cpuOffset == VLGICCPUEndOfInterrupt) {
			uint32_t irq = value & 0x3FF;
			if (irq < VLGIC_MAXIMUM_IRQ) {
				_active[irq] = NO;
				[self refreshLine];
			}
			return;
		}
		if (cpuOffset == VLGICCPUDir) {
			return;
		}
		VLWriteRegister(_cpuInterface, cpuOffset, width, value);
		if (cpuOffset == VLGICCPUPMR || cpuOffset == VLGICCPUControl) {
			[self refreshLine];
		}
	}
}

- (void)writeDistributorAtOffset:(uint32_t)offset width:(uint32_t)width value:(uint32_t)value {
	// ISENABLER 这类寄存器写 1 才生效、读出来是当前状态，所以位图要和影子寄存器同步。
	if (offset >= VLGICDistributorEnableSet && offset < VLGICDistributorEnableSet + 0x20) {
		[self applyBitmapWrite:_enabled
						baseOffsets:@[ @(VLGICDistributorEnableSet), @(VLGICDistributorEnableClear) ]
							offset:offset
						   value:value];
		VLWriteRegister(_distributor, offset, width, value);
		[self refreshLine];
		return;
	}
	if (offset >= VLGICDistributorEnableClear && offset < VLGICDistributorEnableClear + 0x20) {
		[self applyBitmapWrite:_enabled
						baseOffsets:@[ @(VLGICDistributorEnableSet), @(VLGICDistributorEnableClear) ]
							offset:offset
						   value:value];
		VLWriteRegister(_distributor, offset, width, 0);
		[self refreshLine];
		return;
	}
	if (offset >= VLGICDistributorPendingSet && offset < VLGICDistributorPendingSet + 0x20) {
		uint32_t wordIndex = (offset - VLGICDistributorPendingSet) / 4;
		for (uint32_t bit = 0; bit < 32; bit++) {
			uint32_t irq = wordIndex * 32 + bit;
			if ((value & (1u << bit)) != 0 && irq < VLGIC_MAXIMUM_IRQ) {
				_pending[irq] = YES;
			}
		}
		VLWriteRegister(_distributor, offset, width, value);
		[self refreshLine];
		return;
	}
	if (offset >= VLGICDistributorPendingClear && offset < VLGICDistributorPendingClear + 0x20) {
		uint32_t wordIndex = (offset - VLGICDistributorPendingClear) / 4;
		for (uint32_t bit = 0; bit < 32; bit++) {
			uint32_t irq = wordIndex * 32 + bit;
			if ((value & (1u << bit)) != 0 && irq < VLGIC_MAXIMUM_IRQ) {
				_pending[irq] = NO;
			}
		}
		VLWriteRegister(_distributor, VLGICDistributorPendingSet + (offset - VLGICDistributorPendingClear), width, 0);
		[self refreshLine];
		return;
	}
	if (offset >= VLGICDistributorActiveSet && offset < VLGICDistributorActiveSet + 0x20) {
		uint32_t wordIndex = (offset - VLGICDistributorActiveSet) / 4;
		for (uint32_t bit = 0; bit < 32; bit++) {
			uint32_t irq = wordIndex * 32 + bit;
			if ((value & (1u << bit)) != 0 && irq < VLGIC_MAXIMUM_IRQ) {
				_active[irq] = YES;
			}
		}
		VLWriteRegister(_distributor, offset, width, value);
		[self refreshLine];
		return;
	}
	if (offset >= VLGICDistributorActiveClear && offset < VLGICDistributorActiveClear + 0x20) {
		uint32_t wordIndex = (offset - VLGICDistributorActiveClear) / 4;
		for (uint32_t bit = 0; bit < 32; bit++) {
			uint32_t irq = wordIndex * 32 + bit;
			if ((value & (1u << bit)) != 0 && irq < VLGIC_MAXIMUM_IRQ) {
				_active[irq] = NO;
			}
		}
		VLWriteRegister(_distributor, VLGICDistributorActiveSet + (offset - VLGICDistributorActiveClear), width, 0);
		[self refreshLine];
		return;
	}

	VLWriteRegister(_distributor, offset, width, value);
	if (offset == VLGICDistributorControl) {
		[self refreshLine];
	}
}

- (void)applyBitmapWrite:(BOOL *)bitmap
			 baseOffsets:(NSArray<NSNumber *> *)baseOffsets
				  offset:(uint32_t)offset
				   value:(uint32_t)value {
	uint32_t setBase = baseOffsets.firstObject.unsignedIntValue;
	uint32_t clearBase = baseOffsets.lastObject.unsignedIntValue;
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
