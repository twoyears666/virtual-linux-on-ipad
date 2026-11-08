// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 twoyears666

#import "VLTerminalView.h"

#import <stdlib.h>
#import <string.h>

/// 量单元格尺寸用的参考字号；真正绘制时按实测的单元格宽高等比缩放。
static const CGFloat VLTerminalReferenceFontSize = 16.0;
/// 光标方块的不透明度。
static const CGFloat VLTerminalCursorAlpha = 0.55;

#pragma mark - 调色板

/// ANSI 16 色。索引 0–7 标准色，8–15 亮色。
static UIColor *VLTerminalPalette[16];

static void VLTerminalEnsurePalette(void) {
	static BOOL loaded = NO;
	if (loaded) {
		return;
	}
	VLTerminalPalette[0] = [UIColor colorWithRed:0.00 green:0.00 blue:0.00 alpha:1.0];
	VLTerminalPalette[1] = [UIColor colorWithRed:0.67 green:0.00 blue:0.00 alpha:1.0];
	VLTerminalPalette[2] = [UIColor colorWithRed:0.00 green:0.67 blue:0.00 alpha:1.0];
	VLTerminalPalette[3] = [UIColor colorWithRed:0.67 green:0.67 blue:0.00 alpha:1.0];
	VLTerminalPalette[4] = [UIColor colorWithRed:0.00 green:0.00 blue:0.67 alpha:1.0];
	VLTerminalPalette[5] = [UIColor colorWithRed:0.67 green:0.00 blue:0.67 alpha:1.0];
	VLTerminalPalette[6] = [UIColor colorWithRed:0.00 green:0.67 blue:0.67 alpha:1.0];
	VLTerminalPalette[7] = [UIColor colorWithRed:0.75 green:0.75 blue:0.75 alpha:1.0];
	VLTerminalPalette[8] = [UIColor colorWithRed:0.50 green:0.50 blue:0.50 alpha:1.0];
	VLTerminalPalette[9] = [UIColor colorWithRed:1.00 green:0.00 blue:0.00 alpha:1.0];
	VLTerminalPalette[10] = [UIColor colorWithRed:0.00 green:1.00 blue:0.00 alpha:1.0];
	VLTerminalPalette[11] = [UIColor colorWithRed:1.00 green:1.00 blue:0.00 alpha:1.0];
	VLTerminalPalette[12] = [UIColor colorWithRed:0.00 green:0.00 blue:1.00 alpha:1.0];
	VLTerminalPalette[13] = [UIColor colorWithRed:1.00 green:0.00 blue:1.00 alpha:1.0];
	VLTerminalPalette[14] = [UIColor colorWithRed:0.00 green:1.00 blue:1.00 alpha:1.0];
	VLTerminalPalette[15] = [UIColor colorWithRed:1.00 green:1.00 blue:1.00 alpha:1.0];
	loaded = YES;
}

static UIColor *VLTerminalColorForIndex(uint8_t index) {
	VLTerminalEnsurePalette();
	return VLTerminalPalette[index & 0x0F];
}

/// 把码点转成 UTF-16 单元，返回写入的单元数（BMP 之外拆成代理对）。
static NSUInteger VLTerminalUTF16ForCharacter(uint32_t character, unichar *units) {
	if (character == 0) {
		units[0] = ' ';
		return 1;
	}
	if (character <= 0xFFFF) {
		units[0] = (unichar)character;
		return 1;
	}
	uint32_t value = character - 0x10000;
	units[0] = (unichar)(0xD800 + (value >> 10));
	units[1] = (unichar)(0xDC00 + (value & 0x3FF));
	return 2;
}

/// 网格在视图内的位置与单元格尺寸。
typedef struct {
	CGRect grid;
	CGSize cell;
	CGFloat fontSize;
} VLTerminalLayout;

@implementation VLTerminalView {
	CADisplayLink *_displayLink;
	uint64_t _lastGeneration;
}

- (instancetype)initWithFrame:(CGRect)frame {
	self = [super initWithFrame:frame];
	if (self) {
		[self setup];
	}
	return self;
}

- (void)setup {
	self.opaque = YES;
	self.backgroundColor = UIColor.blackColor;
	self.contentMode = UIViewContentModeRedraw;
	// 初始强制画一帧（空白网格 + 光标）。
	_lastGeneration = UINT64_MAX;
}

- (void)dealloc {
	[_displayLink invalidate];
}

- (void)setEmulator:(VLTerminalEmulator *)emulator {
	_emulator = emulator;
	_lastGeneration = UINT64_MAX;
	[self setNeedsDisplay];
}

#pragma mark - 刷新驱动

- (void)willMoveToWindow:(UIWindow *)newWindow {
	[super willMoveToWindow:newWindow];
	if (newWindow == nil) {
		[self stopDisplayLink];
	}
}

- (void)didMoveToWindow {
	[super didMoveToWindow];
	if (self.window != nil) {
		[self startDisplayLink];
		[self setNeedsDisplay];
	} else {
		[self stopDisplayLink];
	}
}

- (void)startDisplayLink {
	if (_displayLink != nil) {
		return;
	}
	_displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(handleDisplayLink:)];
	[_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)stopDisplayLink {
	[_displayLink invalidate];
	_displayLink = nil;
}

/// 只是拿来做节流：内容没变（generation 不变）就不重画。
- (void)handleDisplayLink:(CADisplayLink *)displayLink {
	VLTerminalEmulator *emulator = self.emulator;
	uint64_t generation = emulator != nil ? emulator.generation : 0;
	if (generation == _lastGeneration) {
		return;
	}
	_lastGeneration = generation;
	[self setNeedsDisplay];
}

#pragma mark - 布局

- (VLTerminalLayout)layoutForEmulator:(VLTerminalEmulator *)emulator {
	VLTerminalLayout layout;
	memset(&layout, 0, sizeof(layout));

	CGFloat boundsWidth = CGRectGetWidth(self.bounds);
	CGFloat boundsHeight = CGRectGetHeight(self.bounds);
	if (boundsWidth <= 0.0 || boundsHeight <= 0.0) {
		return layout;
	}

	UIFont *referenceFont = [UIFont monospacedSystemFontOfSize:VLTerminalReferenceFontSize
													   weight:UIFontWeightRegular];
	CGSize glyphSize = [@"M" sizeWithAttributes:@{ NSFontAttributeName: referenceFont }];
	CGFloat cellWidth = MAX(glyphSize.width, 1.0);
	CGFloat cellHeight = MAX(referenceFont.lineHeight, 1.0);

	CGFloat canvasWidth = cellWidth * (CGFloat)emulator.columns;
	CGFloat canvasHeight = cellHeight * (CGFloat)emulator.rows;
	CGFloat scale = MIN(boundsWidth / canvasWidth, boundsHeight / canvasHeight);
	if (scale <= 0.0) {
		return layout;
	}

	layout.cell = CGSizeMake(cellWidth * scale, cellHeight * scale);
	layout.fontSize = VLTerminalReferenceFontSize * scale;
	CGFloat width = layout.cell.width * (CGFloat)emulator.columns;
	CGFloat height = layout.cell.height * (CGFloat)emulator.rows;
	layout.grid = CGRectMake((boundsWidth - width) / 2.0, (boundsHeight - height) / 2.0, width, height);
	return layout;
}

#pragma mark - 绘制

- (void)drawRect:(CGRect)rect {
	[[UIColor blackColor] setFill];
	UIRectFill(self.bounds);

	VLTerminalEmulator *emulator = self.emulator;
	if (emulator == nil) {
		return;
	}
	NSInteger columns = emulator.columns;
	NSInteger rows = emulator.rows;
	if (columns <= 0 || rows <= 0) {
		return;
	}

	VLTerminalLayout layout = [self layoutForEmulator:emulator];
	if (CGRectIsEmpty(layout.grid)) {
		return;
	}

	UIFont *regularFont = [UIFont monospacedSystemFontOfSize:layout.fontSize weight:UIFontWeightRegular];
	UIFont *boldFont = [UIFont monospacedSystemFontOfSize:layout.fontSize weight:UIFontWeightBold];
	CGFloat cellWidth = layout.cell.width;
	CGFloat cellHeight = layout.cell.height;
	CGFloat gridLeft = CGRectGetMinX(layout.grid);
	CGFloat gridTop = CGRectGetMinY(layout.grid);

	// 一段最长可能就是整行；代理对最多翻倍。
	unichar *units = malloc(sizeof(unichar) * (size_t)columns * 2);
	if (units == NULL) {
		return;
	}

	for (NSInteger row = 0; row < rows; row++) {
		NSInteger column = 0;
		while (column < columns) {
			// 先确定这一段（同前景/同背景/同粗细）的范围，再一次性画完。
			VLTerminalCell first = [emulator cellAtColumn:column row:row];
			uint8_t runForeground = first.foreground;
			uint8_t runBackground = first.background;
			BOOL runBold = (first.attributes & VLTerminalAttributeBold) != 0;
			if ((first.attributes & VLTerminalAttributeReverse) != 0) {
				uint8_t swap = runForeground;
				runForeground = runBackground;
				runBackground = swap;
			}

			NSInteger runStart = column;
			NSUInteger unitCount = 0;
			BOOL hasVisibleCharacter = NO;
			while (column < columns) {
				VLTerminalCell cell = [emulator cellAtColumn:column row:row];
				uint8_t foreground = cell.foreground;
				uint8_t background = cell.background;
				BOOL bold = (cell.attributes & VLTerminalAttributeBold) != 0;
				if ((cell.attributes & VLTerminalAttributeReverse) != 0) {
					uint8_t swap = foreground;
					foreground = background;
					background = swap;
				}
				if (foreground != runForeground || background != runBackground || bold != runBold) {
					break;
				}
				if (cell.character != 0 && cell.character != ' ') {
					hasVisibleCharacter = YES;
				}
				unitCount += VLTerminalUTF16ForCharacter(cell.character, &units[unitCount]);
				column++;
			}

			if (runBackground != 0) {
				[VLTerminalColorForIndex(runBackground) setFill];
				UIRectFill(CGRectMake(gridLeft + (CGFloat)runStart * cellWidth,
									  gridTop + (CGFloat)row * cellHeight,
									  (CGFloat)(column - runStart) * cellWidth,
									  cellHeight));
			}

			if (hasVisibleCharacter && unitCount > 0) {
				UIFont *runFont = runBold ? boldFont : regularFont;
				NSString *text = [NSString stringWithCharacters:units length:unitCount];
				NSDictionary *attributes = @{
					NSFontAttributeName : runFont,
					NSForegroundColorAttributeName : VLTerminalColorForIndex(runForeground),
				};
				CGFloat textTop = gridTop + (CGFloat)row * cellHeight +
								  (cellHeight - runFont.lineHeight) / 2.0;
				[text drawAtPoint:CGPointMake(gridLeft + (CGFloat)runStart * cellWidth, textTop)
				   withAttributes:attributes];
			}
		}
	}

	free(units);

	if (emulator.cursorVisible) {
		NSInteger cursorColumn = MIN(MAX(emulator.cursorColumn, 0), columns - 1);
		NSInteger cursorRow = MIN(MAX(emulator.cursorRow, 0), rows - 1);
		VLTerminalCell cell = [emulator cellAtColumn:cursorColumn row:cursorRow];
		uint8_t foreground = cell.foreground;
		if ((cell.attributes & VLTerminalAttributeReverse) != 0) {
			foreground = cell.background;
		}
		UIColor *color = VLTerminalColorForIndex(foreground);
		[[color colorWithAlphaComponent:VLTerminalCursorAlpha] setFill];
		UIRectFill(CGRectMake(gridLeft + (CGFloat)cursorColumn * cellWidth,
							  gridTop + (CGFloat)cursorRow * cellHeight,
							  cellWidth,
							  cellHeight));
	}
}

@end
