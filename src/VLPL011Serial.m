// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 twoyears666

#import "VLPL011Serial.h"

static const uint32_t VLPL011DataRegister = 0x000;
static const uint32_t VLPL011FlagRegister = 0x018;
/// TX FIFO 空（0x80）| RX FIFO 空（0x10）。
static const uint32_t VLPL011FlagsIdle = 0x90;
/// PrimeCell 标识寄存器区：0xFE0–0xFFC 共 8 个字节。
static const uint32_t VLPL011IdentifierStart = 0xFE0;
static const uint32_t VLPL011IdentifierEnd = 0xFFC;
/// PL011 的 PrimeCell ID（PeripheralID0–3、PrimeCellID0–3）。
/// amba 总线在 probe 时会读这一段来核对外设型号，读回全 0 就判 -ENODEV，
/// ttyAMA0 根本不会注册——内核随后打印 `unable to open an initial console`，
/// 用户态连一行输出都拿不到，看起来就是启动卡在 `Freeing unused kernel memory`。
static uint32_t VLPL011IdentifierRegister(uint32_t offset) {
	switch (offset) {
		case 0xFE0: return 0x11;
		case 0xFE4: return 0x10;
		case 0xFE8: return 0x34; // r1p4，驱动匹配时只看低 20 位
		case 0xFEC: return 0x00;
		case 0xFF0: return 0x0D;
		case 0xFF4: return 0xF0;
		case 0xFF8: return 0x05;
		case 0xFFC: return 0xB1;
		default: return 0;
	}
}

@implementation VLPL011Serial {
	NSMutableString *_lineBuffer;
	NSUInteger _writtenCharacterCount;
}

- (instancetype)initWithBaseAddress:(uint64_t)baseAddress {
	self = [super init];
	if (self) {
		_baseAddress = baseAddress;
		_regionSize = 0x1000;
		_lineBuffer = [NSMutableString string];
	}
	return self;
}

- (uint32_t)readAtOffset:(uint32_t)offset width:(uint32_t)width {
	if (offset == VLPL011FlagRegister) {
		return VLPL011FlagsIdle;
	}
	if (offset >= VLPL011IdentifierStart && offset <= VLPL011IdentifierEnd) {
		return VLPL011IdentifierRegister(offset);
	}
	// 数据寄存器恒为空，其余寄存器读 0。
	return 0;
}

- (void)writeAtOffset:(uint32_t)offset width:(uint32_t)width value:(uint32_t)value {
	if (offset != VLPL011DataRegister) {
		return;
	}
	// 只取最低字节，其余当控制寄存器写入忽略。
	uint8_t character = (uint8_t)(value & 0xFF);
	_writtenCharacterCount++;
	if (character == '\r') {
		return;
	}
	[_lineBuffer appendFormat:@"%c", character];
	if (character != '\n') {
		return;
	}
	NSString *line = [_lineBuffer copy];
	_lineBuffer = [NSMutableString string];
	if (self.textHandler != nil) {
		self.textHandler(line);
	}
}

@end
