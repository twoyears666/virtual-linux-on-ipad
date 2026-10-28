#import "VLPL011Serial.h"

static const uint32_t VLPL011DataRegister = 0x000;
static const uint32_t VLPL011FlagRegister = 0x018;
/// TX FIFO 空（0x80）| RX FIFO 空（0x10）。
static const uint32_t VLPL011FlagsIdle = 0x90;

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
