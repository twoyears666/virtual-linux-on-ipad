// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 twoyears666

#import "VLPL011Serial.h"

#import <string.h>

#import "VLInterruptController.h"
#import "VLStartupLog.h"

static const uint32_t VLPL011DataRegister = 0x000;
static const uint32_t VLPL011FlagRegister = 0x018;
static const uint32_t VLPL011InterruptMaskRegister = 0x038;
static const uint32_t VLPL011RawInterruptStatus = 0x03C;
static const uint32_t VLPL011MaskedInterruptStatus = 0x040;
static const uint32_t VLPL011InterruptClearRegister = 0x044;
/// FR 里的 TX FIFO 空位（0x80）与 RX FIFO 空位（0x10）。
static const uint32_t VLPL011FlagTransmitEmpty = 0x80;
static const uint32_t VLPL011FlagReceiveEmpty = 0x10;
static const uint32_t VLPL011FlagsIdle = VLPL011FlagTransmitEmpty | VLPL011FlagReceiveEmpty;
/// RXIM：接收 FIFO 有数据时触发中断。
static const uint32_t VLPL011InterruptReceive = 0x10;
/// PrimeCell 标识寄存器区：0xFE0–0xFFC 共 8 个字节。
static const uint32_t VLPL011IdentifierStart = 0xFE0;
static const uint32_t VLPL011IdentifierEnd = 0xFFC;
/// 接收 FIFO 深度。安装器只会一次塞几个字符，64 足够。
static const NSUInteger VLPL011ReceiveCapacity = 64;
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
	uint32_t _interruptMask;
	uint32_t _rawInterruptStatus;
	uint32_t _interruptNumber;
	__weak VLInterruptController *_interruptController;
	/// 接收 FIFO 是一个环形缓冲。读在 vCPU 线程、写在主线程，所以访问都要加锁。
	uint8_t _receiveBuffer[64];
	NSUInteger _receiveHead;
	NSUInteger _receiveCount;
	/// 还没交给终端渲染的原始字节。攒够一批、遇到换行或超过 50 ms 就冲刷，
	/// 既不会把一个转义序列拆散太久，也不会为每个字符派发一次。
	NSMutableData *_pendingOutput;
	CFAbsoluteTime _lastOutputFlush;
	/// 诊断：注入了几次、客户机读走了多少字节。安装器「按了没反应」时，
	/// 看这两组数就知道是宿主没送进去，还是客户机根本没读。
	NSUInteger _injectedChunkCount;
	NSUInteger _guestReadCount;
}

- (instancetype)initWithBaseAddress:(uint64_t)baseAddress
					interruptNumber:(uint32_t)interruptNumber
			  interruptController:(VLInterruptController *)interruptController {
	self = [super init];
	if (self) {
		_baseAddress = baseAddress;
		_regionSize = 0x1000;
		_lineBuffer = [NSMutableString string];
		_interruptNumber = interruptNumber;
		_interruptController = interruptController;
		_pendingOutput = [NSMutableData data];
		_lastOutputFlush = CFAbsoluteTimeGetCurrent();
	}
	return self;
}

- (void)injectText:(NSString *)text {
	if (text.length == 0) {
		return;
	}
	const char *bytes = text.UTF8String;
	NSUInteger length = strlen(bytes);
	@synchronized (self) {
		for (NSUInteger index = 0; index < length; index++) {
			if (_receiveCount >= VLPL011ReceiveCapacity) {
				break;
			}
			NSUInteger tail = (_receiveHead + _receiveCount) % VLPL011ReceiveCapacity;
			_receiveBuffer[tail] = (uint8_t)bytes[index];
			_receiveCount++;
		}
		_rawInterruptStatus |= VLPL011InterruptReceive;
	}
	if (_injectedChunkCount < 5) {
		_injectedChunkCount++;
		[VLStartupLog log:@"串口注入 %lu 字节（FIFO %lu/64，IMSC=0x%x）",
		 (unsigned long)length, (unsigned long)_receiveCount, _interruptMask];
	}
	[self updateInterruptLine];
}

/// 有数据且 IMSC 打开了 RXIM 就拉中断，否则拉低。电平语义，每次状态变化都要下发。
- (void)updateInterruptLine {
	uint32_t pending = 0;
	@synchronized (self) {
		pending = _rawInterruptStatus & _interruptMask;
	}
	if (pending != 0) {
		[_interruptController setIRQPending:_interruptNumber];
	} else {
		[_interruptController clearIRQPending:_interruptNumber];
	}
}

- (uint32_t)readAtOffset:(uint32_t)offset width:(uint32_t)width {
	if (offset == VLPL011DataRegister) {
		uint8_t character = 0;
		BOOL emptied = NO;
		@synchronized (self) {
			if (_receiveCount > 0) {
				character = _receiveBuffer[_receiveHead];
				_receiveHead = (_receiveHead + 1) % VLPL011ReceiveCapacity;
				_receiveCount--;
				if (_receiveCount == 0) {
					_rawInterruptStatus &= ~VLPL011InterruptReceive;
					emptied = YES;
				}
			}
		}
		// 读空了就把中断线拉低，否则电平会一直挂着。
		if (emptied) {
			[self updateInterruptLine];
		}
		// 只有第一次读要留证：说明客户机确实把串口输入读走了。
		if (_guestReadCount < 1 && character != 0) {
			_guestReadCount++;
			[VLStartupLog log:@"客户机已读取串口输入（首字节 0x%02x）", character];
		}
		return character;
	}
	if (offset == VLPL011FlagRegister) {
		BOOL empty = NO;
		@synchronized (self) {
			empty = _receiveCount == 0;
		}
		return empty ? VLPL011FlagsIdle : VLPL011FlagTransmitEmpty;
	}
	if (offset == VLPL011InterruptMaskRegister) {
		@synchronized (self) {
			return _interruptMask;
		}
	}
	if (offset == VLPL011RawInterruptStatus) {
		@synchronized (self) {
			return _rawInterruptStatus;
		}
	}
	if (offset == VLPL011MaskedInterruptStatus) {
		@synchronized (self) {
			return _rawInterruptStatus & _interruptMask;
		}
	}
	if (offset >= VLPL011IdentifierStart && offset <= VLPL011IdentifierEnd) {
		return VLPL011IdentifierRegister(offset);
	}
	// 其余寄存器读 0。
	return 0;
}

- (void)writeAtOffset:(uint32_t)offset width:(uint32_t)width value:(uint32_t)value {
	if (offset == VLPL011InterruptMaskRegister) {
		@synchronized (self) {
			_interruptMask = value;
		}
		[self updateInterruptLine];
		return;
	}
	if (offset == VLPL011InterruptClearRegister) {
		@synchronized (self) {
			_rawInterruptStatus &= ~value;
		}
		[self updateInterruptLine];
		return;
	}
	if (offset != VLPL011DataRegister) {
		return;
	}
	// 只取最低字节，其余当控制寄存器写入忽略。
	uint8_t character = (uint8_t)(value & 0xFF);
	_writtenCharacterCount++;

	// 原始字节另走一路给终端渲染：转义序列必须原样保留。
	if (self.outputHandler != nil) {
		[_pendingOutput appendBytes:&character length:1];
		CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
		if (character == '\n' || _pendingOutput.length >= 512 ||
			now - _lastOutputFlush >= 0.05) {
			NSData *chunk = [_pendingOutput copy];
			[_pendingOutput setLength:0];
			_lastOutputFlush = now;
			self.outputHandler(chunk);
		}
	}

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
