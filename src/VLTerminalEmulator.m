// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 twoyears666

#import "VLTerminalEmulator.h"

#import <stdlib.h>
#import <string.h>

/// d-i 的串口控制台就是 80x25，客户机不会去改这个尺寸。
static const NSInteger VLTerminalColumnCount = 80;
static const NSInteger VLTerminalRowCount = 25;
/// CSI 参数最多收这么多个，超出的丢弃（够 SGR 与真终端用）。
static const NSInteger VLTerminalMaxParameters = 16;
/// 缺省前景/背景：浅灰 on 黑。
static const uint8_t VLTerminalDefaultForeground = 7;
static const uint8_t VLTerminalDefaultBackground = 0;
/// 解码失败时写一个替换字符，避免整行错位。
static const uint32_t VLTerminalReplacementCharacter = 0xFFFD;

typedef NS_ENUM(uint8_t, VLTerminalParserState) {
	VLTerminalParserStateGround = 0,
	VLTerminalParserStateEscape,
	VLTerminalParserStateCharset,
	VLTerminalParserStateCSI,
	VLTerminalParserStateOSC,
	VLTerminalParserStateStringIgnore,
};

@implementation VLTerminalEmulator {
	/// 当前屏：指向 _mainCells 或 _altCells。
	VLTerminalCell *_cells;
	VLTerminalCell *_mainCells;
	VLTerminalCell *_altCells;
	BOOL _alternateScreen;

	NSInteger _cursorColumn;
	NSInteger _cursorRow;
	BOOL _cursorVisible;
	uint64_t _generation;

	uint8_t _foreground;
	uint8_t _background;
	uint8_t _attributes;

	NSInteger _scrollTop;
	NSInteger _scrollBottom;

	/// ESC 7 / ESC 8 与 CSI s / CSI u 共用同一组保存位置。
	NSInteger _savedCursorColumn;
	NSInteger _savedCursorRow;
	NSInteger _savedForeground;
	NSInteger _savedBackground;
	NSInteger _savedAttributes;

	/// 进备用屏前的主屏光标，退出时恢复。
	NSInteger _mainScreenCursorColumn;
	NSInteger _mainScreenCursorRow;

	VLTerminalParserState _parserState;
	uint8_t _csiPrefix;
	NSInteger _csiParameters[VLTerminalMaxParameters];
	NSInteger _csiParameterCount;
	NSInteger _csiCurrentParameter;

	uint8_t _utf8Pending[4];
	NSUInteger _utf8PendingCount;
	NSUInteger _utf8ExpectedCount;
}

- (instancetype)init {
	self = [super init];
	if (self) {
		_mainCells = calloc((size_t)(VLTerminalColumnCount * VLTerminalRowCount), sizeof(VLTerminalCell));
		_altCells = calloc((size_t)(VLTerminalColumnCount * VLTerminalRowCount), sizeof(VLTerminalCell));
		if (_mainCells == NULL || _altCells == NULL) {
			free(_mainCells);
			free(_altCells);
			return nil;
		}
		_cells = _mainCells;
		[self resetState];
	}
	return self;
}

- (void)dealloc {
	free(_mainCells);
	free(_altCells);
}

- (void)resetState {
	_alternateScreen = NO;
	_cells = _mainCells;
	memset(_mainCells, 0, (size_t)(VLTerminalColumnCount * VLTerminalRowCount) * sizeof(VLTerminalCell));
	memset(_altCells, 0, (size_t)(VLTerminalColumnCount * VLTerminalRowCount) * sizeof(VLTerminalCell));

	_cursorColumn = 0;
	_cursorRow = 0;
	_cursorVisible = YES;
	_foreground = VLTerminalDefaultForeground;
	_background = VLTerminalDefaultBackground;
	_attributes = 0;
	_scrollTop = 0;
	_scrollBottom = VLTerminalRowCount - 1;
	_savedCursorColumn = 0;
	_savedCursorRow = 0;
	_savedForeground = VLTerminalDefaultForeground;
	_savedBackground = VLTerminalDefaultBackground;
	_savedAttributes = 0;
	_mainScreenCursorColumn = 0;
	_mainScreenCursorRow = 0;
	_parserState = VLTerminalParserStateGround;
	_csiPrefix = 0;
	_csiParameterCount = 0;
	_csiCurrentParameter = -1;
	_utf8PendingCount = 0;
	_utf8ExpectedCount = 0;
	_generation++;
}

#pragma mark - 只读属性

- (NSInteger)columns {
	return VLTerminalColumnCount;
}

- (NSInteger)rows {
	return VLTerminalRowCount;
}

- (NSInteger)cursorColumn {
	@synchronized (self) {
		return _cursorColumn;
	}
}

- (NSInteger)cursorRow {
	@synchronized (self) {
		return _cursorRow;
	}
}

- (BOOL)cursorVisible {
	@synchronized (self) {
		return _cursorVisible;
	}
}

- (uint64_t)generation {
	@synchronized (self) {
		return _generation;
	}
}

- (VLTerminalCell)cellAtColumn:(NSInteger)column row:(NSInteger)row {
	if (column < 0 || column >= VLTerminalColumnCount || row < 0 || row >= VLTerminalRowCount) {
		VLTerminalCell empty;
		memset(&empty, 0, sizeof(empty));
		return empty;
	}
	@synchronized (self) {
		return _cells[row * VLTerminalColumnCount + column];
	}
}

#pragma mark - 输入

- (void)feed:(NSData *)data {
	if (data.length == 0) {
		return;
	}
	const uint8_t *bytes = (const uint8_t *)data.bytes;
	NSUInteger length = data.length;
	@synchronized (self) {
		for (NSUInteger index = 0; index < length; index++) {
			[self consumeByte:bytes[index]];
		}
	}
}

- (void)consumeByte:(uint8_t)byte {
	switch (_parserState) {
		case VLTerminalParserStateGround:
			if (byte == 0x1B) {
				_parserState = VLTerminalParserStateEscape;
				return;
			}
			if (byte < 0x20) {
				[self executeControl:byte];
				return;
			}
			if (byte == 0x7F) {
				return;
			}
			[self consumeUTF8Byte:byte];
			return;

		case VLTerminalParserStateEscape:
			[self handleEscape:byte];
			return;

		case VLTerminalParserStateCharset:
			// ESC ( X / ESC ) X / ESC # 8 之类：吃掉该字节即结束。
			_parserState = VLTerminalParserStateGround;
			return;

		case VLTerminalParserStateCSI:
			[self handleCSIByte:byte];
			return;

		case VLTerminalParserStateOSC:
			if (byte == 0x07) {
				_parserState = VLTerminalParserStateGround;
			} else if (byte == 0x1B) {
				_parserState = VLTerminalParserStateEscape;
			}
			return;

		case VLTerminalParserStateStringIgnore:
			if (byte == 0x1B) {
				_parserState = VLTerminalParserStateEscape;
			}
			return;
	}
}

#pragma mark - 控制字符

- (void)executeControl:(uint8_t)byte {
	// 控制字符打断未完成的 UTF-8 序列。
	_utf8PendingCount = 0;
	_utf8ExpectedCount = 0;

	switch (byte) {
		case 0x08: // \b
			if (_cursorColumn > 0) {
				_cursorColumn--;
				_generation++;
			}
			return;
		case 0x09: { // \t
			NSInteger next = ((_cursorColumn / 8) + 1) * 8;
			if (next > VLTerminalColumnCount - 1) {
				next = VLTerminalColumnCount - 1;
			}
			if (next != _cursorColumn) {
				_cursorColumn = next;
				_generation++;
			}
			return;
		}
		case 0x0A: // \n
		case 0x0B: // \v
		case 0x0C: // \f
			[self lineFeed];
			return;
		case 0x0D: // \r
			if (_cursorColumn != 0) {
				_cursorColumn = 0;
				_generation++;
			}
			return;
		case 0x07: // \a
		case 0x0E: // SO
		case 0x0F: // SI
			return;
		default:
			return;
	}
}

- (void)handleEscape:(uint8_t)byte {
	_parserState = VLTerminalParserStateGround;

	switch (byte) {
		case '[':
			_csiPrefix = 0;
			_csiParameterCount = 0;
			_csiCurrentParameter = -1;
			_parserState = VLTerminalParserStateCSI;
			return;
		case ']':
			_parserState = VLTerminalParserStateOSC;
			return;
		case 'P': // DCS
		case 'X': // SOS
		case '^': // PM
		case '_': // APC
			_parserState = VLTerminalParserStateStringIgnore;
			return;
		case '(':
		case ')':
		case '*':
		case '+':
		case '-':
		case '.':
		case '/':
		case '#':
		case '%':
		case ' ':
			// 字符集/键盘映射选择：后面跟一个字节，一起跳过。
			_parserState = VLTerminalParserStateCharset;
			return;
		case '7':
			[self saveCursor];
			return;
		case '8':
			[self restoreCursor];
			return;
		case 'M':
			[self reverseIndex];
			return;
		case 'D':
			[self lineFeed];
			return;
		case 'E':
			_cursorColumn = 0;
			[self lineFeed];
			_generation++;
			return;
		case 'c':
			[self resetState];
			return;
		case '=':
		case '>':
			// 应用/数字键盘模式，忽略。
			return;
		default:
			// 两字节序列的未识别终止符一律安全跳过。
			return;
	}
}

#pragma mark - CSI

- (void)handleCSIByte:(uint8_t)byte {
	if (byte >= '0' && byte <= '9') {
		if (_csiCurrentParameter < 0) {
			_csiCurrentParameter = 0;
		}
		if (_csiCurrentParameter < 100000) {
			_csiCurrentParameter = _csiCurrentParameter * 10 + (NSInteger)(byte - '0');
		}
		return;
	}
	if (byte == ';') {
		[self pushCSIParameter];
		return;
	}
	if (byte == '?' || byte == '>' || byte == '=' || byte == '<' || byte == '!') {
		_csiPrefix = byte;
		return;
	}
	if (byte == 0x1B) {
		_parserState = VLTerminalParserStateEscape;
		return;
	}
	if (byte < 0x20) {
		// CSI 中间夹的控制字符照常执行，序列继续。
		[self executeControl:byte];
		return;
	}
	if (byte >= 0x40 && byte <= 0x7E) {
		[self pushCSIParameter];
		[self dispatchCSI:byte];
		_parserState = VLTerminalParserStateGround;
		_csiPrefix = 0;
		_csiParameterCount = 0;
		_csiCurrentParameter = -1;
		return;
	}
	// 参数与终止符之间的中间字节（空格、'$' 等）直接丢掉。
}

- (void)pushCSIParameter {
	if (_csiParameterCount < VLTerminalMaxParameters) {
		_csiParameters[_csiParameterCount++] = _csiCurrentParameter;
	}
	_csiCurrentParameter = -1;
}

- (NSInteger)parameterAtIndex:(NSInteger)index defaultValue:(NSInteger)fallback {
	if (index < 0 || index >= _csiParameterCount) {
		return fallback;
	}
	NSInteger value = _csiParameters[index];
	return value < 0 ? fallback : value;
}

- (void)dispatchCSI:(uint8_t)final {
	NSInteger count = [self parameterAtIndex:0 defaultValue:1];

	switch (final) {
		case 'A':
			[self moveCursorColumnBy:0 rowBy:-count];
			return;
		case 'B':
			[self moveCursorColumnBy:0 rowBy:count];
			return;
		case 'C':
			[self moveCursorColumnBy:count rowBy:0];
			return;
		case 'D':
			[self moveCursorColumnBy:-count rowBy:0];
			return;
		case 'H':
		case 'f': {
			NSInteger row = [self parameterAtIndex:0 defaultValue:1] - 1;
			NSInteger column = [self parameterAtIndex:1 defaultValue:1] - 1;
			[self setCursorColumn:column row:row];
			return;
		}
		case 'G':
			[self setCursorColumn:count - 1 row:_cursorRow];
			return;
		case 'd':
			[self setCursorColumn:_cursorColumn row:count - 1];
			return;
		case 'J':
			[self eraseDisplay:[self parameterAtIndex:0 defaultValue:0]];
			return;
		case 'K':
			[self eraseLine:[self parameterAtIndex:0 defaultValue:0]];
			return;
		case 'm':
			[self applySGR];
			return;
		case 'h':
		case 'l':
			[self applyModes:final == 'h'];
			return;
		case 'r': {
			NSInteger top = [self parameterAtIndex:0 defaultValue:1] - 1;
			NSInteger bottom = [self parameterAtIndex:1 defaultValue:VLTerminalRowCount] - 1;
			if (top < 0) {
				top = 0;
			}
			if (bottom >= VLTerminalRowCount) {
				bottom = VLTerminalRowCount - 1;
			}
			if (top < bottom) {
				_scrollTop = top;
				_scrollBottom = bottom;
				_cursorColumn = 0;
				_cursorRow = top;
				_generation++;
			} else {
				_scrollTop = 0;
				_scrollBottom = VLTerminalRowCount - 1;
				_generation++;
			}
			return;
		}
		case 'S':
			[self scrollUp:count];
			return;
		case 'T':
			[self scrollDown:count];
			return;
		case 's':
			[self saveCursor];
			return;
		case 'u':
			[self restoreCursor];
			return;
		default:
			// 'q' 'n' 'c' 't' 'p' 等一律安全忽略。
			return;
	}
}

#pragma mark - 光标与移动

- (void)setCursorColumn:(NSInteger)column row:(NSInteger)row {
	if (column < 0) {
		column = 0;
	}
	if (column > VLTerminalColumnCount - 1) {
		column = VLTerminalColumnCount - 1;
	}
	if (row < 0) {
		row = 0;
	}
	if (row > VLTerminalRowCount - 1) {
		row = VLTerminalRowCount - 1;
	}
	if (column == _cursorColumn && row == _cursorRow) {
		return;
	}
	_cursorColumn = column;
	_cursorRow = row;
	// 光标方块也是画面的一部分，移动同样要让 UI 重画。
	_generation++;
}

- (void)moveCursorColumnBy:(NSInteger)columnDelta rowBy:(NSInteger)rowDelta {
	[self setCursorColumn:_cursorColumn + columnDelta row:_cursorRow + rowDelta];
}

- (void)saveCursor {
	_savedCursorColumn = _cursorColumn;
	_savedCursorRow = _cursorRow;
	_savedForeground = _foreground;
	_savedBackground = _background;
	_savedAttributes = _attributes;
}

- (void)restoreCursor {
	_foreground = (uint8_t)_savedForeground;
	_background = (uint8_t)_savedBackground;
	_attributes = (uint8_t)_savedAttributes;
	[self setCursorColumn:_savedCursorColumn row:_savedCursorRow];
}

#pragma mark - 写字符

- (void)writeCharacter:(uint32_t)character {
	VLTerminalCell *cell = &_cells[_cursorRow * VLTerminalColumnCount + _cursorColumn];
	cell->character = character;
	cell->foreground = _foreground;
	cell->background = _background;
	cell->attributes = _attributes;

	_cursorColumn++;
	if (_cursorColumn >= VLTerminalColumnCount) {
		_cursorColumn = 0;
		[self lineFeed];
	}
	_generation++;
}

/// 下移一行；在滚动区底部时整体上滚。
- (void)lineFeed {
	if (_cursorRow == _scrollBottom) {
		[self scrollUp:1];
		return;
	}
	if (_cursorRow < VLTerminalRowCount - 1) {
		_cursorRow++;
		_generation++;
	}
}

/// ESC M：在滚动区顶部时整体下滚一行。
- (void)reverseIndex {
	if (_cursorRow == _scrollTop) {
		[self scrollDown:1];
		return;
	}
	if (_cursorRow > 0) {
		_cursorRow--;
		_generation++;
	}
}

#pragma mark - 滚屏与擦除

- (void)fillRow:(NSInteger)row {
	VLTerminalCell *line = &_cells[row * VLTerminalColumnCount];
	for (NSInteger column = 0; column < VLTerminalColumnCount; column++) {
		line[column].character = 0;
		line[column].foreground = _foreground;
		line[column].background = _background;
		line[column].attributes = 0;
	}
}

- (void)scrollUp:(NSInteger)count {
	NSInteger height = _scrollBottom - _scrollTop + 1;
	if (height <= 0 || count <= 0) {
		return;
	}
	if (count > height) {
		count = height;
	}
	NSInteger kept = height - count;
	if (kept > 0) {
		memmove(&_cells[_scrollTop * VLTerminalColumnCount],
				&_cells[(_scrollTop + count) * VLTerminalColumnCount],
				(size_t)(kept * VLTerminalColumnCount) * sizeof(VLTerminalCell));
	}
	for (NSInteger row = _scrollBottom - count + 1; row <= _scrollBottom; row++) {
		[self fillRow:row];
	}
	_generation++;
}

- (void)scrollDown:(NSInteger)count {
	NSInteger height = _scrollBottom - _scrollTop + 1;
	if (height <= 0 || count <= 0) {
		return;
	}
	if (count > height) {
		count = height;
	}
	NSInteger kept = height - count;
	if (kept > 0) {
		memmove(&_cells[(_scrollTop + count) * VLTerminalColumnCount],
				&_cells[_scrollTop * VLTerminalColumnCount],
				(size_t)(kept * VLTerminalColumnCount) * sizeof(VLTerminalCell));
	}
	for (NSInteger row = _scrollTop; row < _scrollTop + count; row++) {
		[self fillRow:row];
	}
	_generation++;
}

- (void)eraseDisplay:(NSInteger)mode {
	if (mode == 2) {
		for (NSInteger row = 0; row < VLTerminalRowCount; row++) {
			[self fillRow:row];
		}
		_generation++;
		return;
	}
	if (mode == 0) {
		for (NSInteger column = _cursorColumn; column < VLTerminalColumnCount; column++) {
			VLTerminalCell *cell = &_cells[_cursorRow * VLTerminalColumnCount + column];
			cell->character = 0;
			cell->foreground = _foreground;
			cell->background = _background;
			cell->attributes = 0;
		}
		for (NSInteger row = _cursorRow + 1; row < VLTerminalRowCount; row++) {
			[self fillRow:row];
		}
		_generation++;
		return;
	}
	if (mode == 1) {
		for (NSInteger row = 0; row < _cursorRow; row++) {
			[self fillRow:row];
		}
		for (NSInteger column = 0; column <= _cursorColumn && column < VLTerminalColumnCount; column++) {
			VLTerminalCell *cell = &_cells[_cursorRow * VLTerminalColumnCount + column];
			cell->character = 0;
			cell->foreground = _foreground;
			cell->background = _background;
			cell->attributes = 0;
		}
		_generation++;
	}
}

- (void)eraseLine:(NSInteger)mode {
	NSInteger start = 0;
	NSInteger end = VLTerminalColumnCount - 1;
	if (mode == 0) {
		start = _cursorColumn;
	} else if (mode == 1) {
		end = _cursorColumn;
	} else if (mode != 2) {
		return;
	}
	for (NSInteger column = start; column <= end; column++) {
		VLTerminalCell *cell = &_cells[_cursorRow * VLTerminalColumnCount + column];
		cell->character = 0;
		cell->foreground = _foreground;
		cell->background = _background;
		cell->attributes = 0;
	}
	_generation++;
}

#pragma mark - SGR 与模式

- (void)applySGR {
	NSInteger count = _csiParameterCount;
	if (count == 0) {
		count = 1;
	}
	for (NSInteger index = 0; index < count; index++) {
		NSInteger code = index < _csiParameterCount ? _csiParameters[index] : -1;
		if (code < 0) {
			code = 0;
		}
		if (code == 0) {
			_foreground = VLTerminalDefaultForeground;
			_background = VLTerminalDefaultBackground;
			_attributes = 0;
		} else if (code == 1) {
			_attributes |= VLTerminalAttributeBold;
		} else if (code == 7) {
			_attributes |= VLTerminalAttributeReverse;
		} else if (code == 22) {
			_attributes &= (uint8_t)~VLTerminalAttributeBold;
		} else if (code == 27) {
			_attributes &= (uint8_t)~VLTerminalAttributeReverse;
		} else if (code >= 30 && code <= 37) {
			_foreground = (uint8_t)(code - 30);
		} else if (code == 39) {
			_foreground = VLTerminalDefaultForeground;
		} else if (code >= 40 && code <= 47) {
			_background = (uint8_t)(code - 40);
		} else if (code == 49) {
			_background = VLTerminalDefaultBackground;
		} else if (code >= 90 && code <= 97) {
			_foreground = (uint8_t)(code - 90 + 8);
		} else if (code >= 100 && code <= 107) {
			_background = (uint8_t)(code - 100 + 8);
		}
	}
	_generation++;
}

- (void)applyModes:(BOOL)enable {
	if (_csiPrefix != '?') {
		// 非私有模式（插入/换行等）不支持，忽略。
		return;
	}
	for (NSInteger index = 0; index < _csiParameterCount; index++) {
		NSInteger mode = _csiParameters[index];
		if (mode == 25) {
			if (_cursorVisible != enable) {
				_cursorVisible = enable;
				_generation++;
			}
		} else if (mode == 1049 || mode == 47 || mode == 1047) {
			if (enable) {
				[self enterAlternateScreen];
			} else {
				[self leaveAlternateScreen];
			}
		}
	}
}

- (void)enterAlternateScreen {
	if (_alternateScreen) {
		return;
	}
	_alternateScreen = YES;
	memcpy(_mainCells, _cells, (size_t)(VLTerminalColumnCount * VLTerminalRowCount) * sizeof(VLTerminalCell));
	_mainScreenCursorColumn = _cursorColumn;
	_mainScreenCursorRow = _cursorRow;
	_cells = _altCells;
	memset(_altCells, 0, (size_t)(VLTerminalColumnCount * VLTerminalRowCount) * sizeof(VLTerminalCell));
	_cursorColumn = 0;
	_cursorRow = 0;
	_generation++;
}

- (void)leaveAlternateScreen {
	if (!_alternateScreen) {
		return;
	}
	_alternateScreen = NO;
	_cells = _mainCells;
	_cursorColumn = _mainScreenCursorColumn;
	_cursorRow = _mainScreenCursorRow;
	_generation++;
}

#pragma mark - UTF-8

- (void)consumeUTF8Byte:(uint8_t)byte {
	if (byte < 0x80) {
		if (_utf8PendingCount > 0) {
			_utf8PendingCount = 0;
			_utf8ExpectedCount = 0;
			[self writeCharacter:VLTerminalReplacementCharacter];
		}
		[self writeCharacter:byte];
		return;
	}

	if (_utf8PendingCount == 0) {
		NSUInteger expected = 0;
		if (byte >= 0xC2 && byte <= 0xDF) {
			expected = 1;
		} else if (byte >= 0xE0 && byte <= 0xEF) {
			expected = 2;
		} else if (byte >= 0xF0 && byte <= 0xF4) {
			expected = 3;
		} else {
			// 孤立续字节或非法起始字节，丢掉。
			return;
		}
		_utf8Pending[0] = byte;
		_utf8PendingCount = 1;
		_utf8ExpectedCount = expected;
		return;
	}

	if ((byte & 0xC0) != 0x80) {
		_utf8PendingCount = 0;
		_utf8ExpectedCount = 0;
		[self writeCharacter:VLTerminalReplacementCharacter];
		[self consumeUTF8Byte:byte];
		return;
	}

	_utf8Pending[_utf8PendingCount++] = byte;
	if (_utf8PendingCount < _utf8ExpectedCount + 1) {
		return;
	}

	uint32_t codepoint = 0;
	switch (_utf8ExpectedCount) {
		case 1:
			codepoint = (uint32_t)(_utf8Pending[0] & 0x1F);
			break;
		case 2:
			codepoint = (uint32_t)(_utf8Pending[0] & 0x0F);
			break;
		default:
			codepoint = (uint32_t)(_utf8Pending[0] & 0x07);
			break;
	}
	for (NSUInteger index = 1; index < _utf8PendingCount; index++) {
		codepoint = (codepoint << 6) | (uint32_t)(_utf8Pending[index] & 0x3F);
	}
	_utf8PendingCount = 0;
	_utf8ExpectedCount = 0;
	[self writeCharacter:codepoint];
}

@end
