// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 twoyears666

#import "VLKeyInputView.h"

#import "VLLinuxVirtualMachine.h"

#pragma mark - 按键映射

/// iOS 字符 → Linux evdev 按键码（KEY_A = 30 这一套）。
/// 返回值 0 表示这个字符没有对应按键，直接忽略。
static const uint16_t VLLowercaseKeycodes[26] = {
	30, 48, 46, 32, 18, 33, 34, 35, 23, 36, 37, 38, 50,
	49, 24, 25, 16, 19, 31, 20, 22, 47, 17, 45, 21, 44,
};

static uint16_t VLKeycodeForCharacter(unichar character, BOOL *needsShift) {
	if (needsShift != NULL) {
		*needsShift = NO;
	}
	if (character >= 'a' && character <= 'z') {
		return VLLowercaseKeycodes[character - 'a'];
	}
	if (character >= 'A' && character <= 'Z') {
		if (needsShift != NULL) {
			*needsShift = YES;
		}
		return VLLowercaseKeycodes[character - 'A'];
	}
	if (character >= '1' && character <= '9') {
		return (uint16_t)(character - '1' + 2);
	}
	if (character == '0') {
		return 11;
	}
	if (character == ' ') {
		return 57;
	}
	if (character == '\n' || character == '\r') {
		return 28;
	}
	if (character == '\t') {
		return 15;
	}
	switch (character) {
		case '-': return 12;
		case '=': return 13;
		case '[': return 26;
		case ']': return 27;
		case ';': return 39;
		case '\'': return 40;
		case '`': return 41;
		case '\\': return 43;
		case ',': return 51;
		case '.': return 52;
		case '/': return 53;
		// 下面这些是按住 Shift 才打出来的符号。
		case '!': if (needsShift != NULL) { *needsShift = YES; } return 2;
		case '@': if (needsShift != NULL) { *needsShift = YES; } return 3;
		case '#': if (needsShift != NULL) { *needsShift = YES; } return 4;
		case '$': if (needsShift != NULL) { *needsShift = YES; } return 5;
		case '%': if (needsShift != NULL) { *needsShift = YES; } return 6;
		case '^': if (needsShift != NULL) { *needsShift = YES; } return 7;
		case '&': if (needsShift != NULL) { *needsShift = YES; } return 8;
		case '*': if (needsShift != NULL) { *needsShift = YES; } return 9;
		case '(': if (needsShift != NULL) { *needsShift = YES; } return 10;
		case ')': if (needsShift != NULL) { *needsShift = YES; } return 11;
		case '_': if (needsShift != NULL) { *needsShift = YES; } return 12;
		case '+': if (needsShift != NULL) { *needsShift = YES; } return 13;
		case '{': if (needsShift != NULL) { *needsShift = YES; } return 26;
		case '}': if (needsShift != NULL) { *needsShift = YES; } return 27;
		case ':': if (needsShift != NULL) { *needsShift = YES; } return 39;
		case '"': if (needsShift != NULL) { *needsShift = YES; } return 40;
		case '~': if (needsShift != NULL) { *needsShift = YES; } return 41;
		case '|': if (needsShift != NULL) { *needsShift = YES; } return 43;
		case '<': if (needsShift != NULL) { *needsShift = YES; } return 51;
		case '>': if (needsShift != NULL) { *needsShift = YES; } return 52;
		case '?': if (needsShift != NULL) { *needsShift = YES; } return 53;
	}
	return 0;
}

/// HID 用法号 → evdev 按键码。只映射字符键以外的那些键。
static uint16_t VLKeycodeForHIDUsage(uint16_t usage) {
	switch (usage) {
		case 0x29: return 1;    // Esc
		case 0x2B: return 15;   // Tab
		case 0x28: return 28;   // Return
		case 0x58: return 96;   // 小键盘回车
		case 0x2A: return 14;   // Backspace
		case 0x4C: return 111;  // Delete
		case 0x4F: return 106;  // Right
		case 0x50: return 105;  // Left
		case 0x51: return 108;  // Down
		case 0x52: return 103;  // Up
		case 0x4A: return 102;  // Home
		case 0x4D: return 107;  // End
		case 0x4B: return 104;  // PageUp
		case 0x4E: return 109;  // PageDown
		case 0x49: return 110;  // Insert
		case 0x46: return 119;  // PrintScreen
		case 0x47: return 99;   // Pause
		case 0xE0: return 29;   // 左 Ctrl
		case 0xE1: return 42;   // 左 Shift
		case 0xE2: return 56;   // 左 Alt
		case 0xE3: return 125;  // 左 Cmd
		case 0xE4: return 97;   // 右 Ctrl
		case 0xE5: return 54;   // 右 Shift
		case 0xE6: return 100;  // 右 Alt
		case 0xE7: return 126;  // 右 Cmd
		default: return 0;
	}
}

/// 功能键对应的终端字符序列。安装器（d-i）的 stdin 是串口控制台，
/// 它不读 evdev，只认 tty 上的字节，所以这些键也要往串口送一份。
static NSString *VLTextForSpecialKeycode(uint16_t keycode) {
	switch (keycode) {
		case 1: return @"\x1b";       // Esc
		case 15: return @"\t";        // Tab
		case 28: return @"\r";        // Enter
		case 96: return @"\r";        // 小键盘回车
		case 14: return @"\x7f";      // Backspace
		case 103: return @"\x1b[A";   // Up
		case 108: return @"\x1b[B";   // Down
		case 106: return @"\x1b[C";   // Right
		case 105: return @"\x1b[D";   // Left
		case 102: return @"\x1b[H";   // Home
		case 107: return @"\x1b[F";   // End
		case 104: return @"\x1b[5~";  // PageUp
		case 109: return @"\x1b[6~";  // PageDown
		case 111: return @"\x1b[3~";  // Delete
		default: return nil;
	}
}

/// 控制字符（退格、回车、Tab、Esc）→ evdev 按键码。
/// 这几种键在 UIKit 里 characters 是 0x08/0x0d 这样的控制字符，不能按普通字符走。
static uint16_t VLKeycodeForControlCharacter(unichar character) {
	switch (character) {
		case 0x08: case 0x7F: return 14;  // Backspace / Delete
		case 0x0D: case 0x0A: return 28;  // Return
		case 0x09: return 15;             // Tab
		case 0x1B: return 1;              // Esc
	}
	return 0;
}

#pragma mark -

@interface VLKeyInputView () <UITextFieldDelegate>

@property (nonatomic, strong) VLLinuxVirtualMachine *machine;
/// 已按下、还没抬起的键（HID 用法号 → evdev 按键码），用于释放配对。
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *pressedKeys;
/// 只有用户点了键盘按钮才创建并唤起它：平时连第一响应者都不占，
/// 硬件键盘事件始终落在本视图上。
@property (nonatomic, strong) UITextField *softKeyboardField;

@end

@implementation VLKeyInputView

- (instancetype)initWithMachine:(VLLinuxVirtualMachine *)machine {
	self = [super initWithFrame:CGRectZero];
	if (self) {
		_machine = machine;
		_pressedKeys = [NSMutableDictionary dictionary];
		self.backgroundColor = [UIColor colorWithWhite:0.09 alpha:0.94];
		[self buildKeys];
		// 硬件键盘事件只发给第一响应者，本视图必须能成为它。
		self.userInteractionEnabled = YES;
	}
	return self;
}

- (BOOL)canBecomeFirstResponder {
	return YES;
}

- (void)focus {
	if (self.softKeyboardField.isFirstResponder) {
		return;
	}
	[self becomeFirstResponder];
}

- (void)showSoftKeyboard {
	if (self.softKeyboardField == nil) {
		UITextField *field = [[UITextField alloc] initWithFrame:CGRectMake(0.0, 0.0, 1.0, 1.0)];
		field.delegate = self;
		field.autocorrectionType = UITextAutocorrectionTypeNo;
		field.autocapitalizationType = UITextAutocapitalizationTypeNone;
		field.spellCheckingType = UITextSpellCheckingTypeNo;
		field.smartQuotesType = UITextSmartQuotesTypeNo;
		field.smartDashesType = UITextSmartDashesTypeNo;
		field.keyboardAppearance = UIKeyboardAppearanceDark;
		field.textColor = UIColor.clearColor;
		field.tintColor = UIColor.clearColor;
		// 常驻一个空格：内容为空时退格不会触发 delegate，删不掉字符。
		field.text = @" ";
		// 放在可视区域外，但必须在视图树里才能成为第一响应者。
		[self addSubview:field];
		self.softKeyboardField = field;
	}
	[self.softKeyboardField becomeFirstResponder];
}

- (void)hideSoftKeyboard {
	[self.softKeyboardField resignFirstResponder];
	[self becomeFirstResponder];
}

#pragma mark - UITextFieldDelegate

- (BOOL)textField:(UITextField *)textField
	shouldChangeCharactersInRange:(NSRange)range
				replacementString:(NSString *)string {
	if (string.length == 0) {
		// 退格：串口侧发 DEL，evdev 侧发 Backspace。
		[self.machine sendText:@"\x7f"];
		[self.machine sendKeycode:14 pressed:YES];
		[self.machine sendKeycode:14 pressed:NO];
	} else {
		for (NSUInteger index = 0; index < string.length; index++) {
			[self sendCharacter:[string characterAtIndex:index]];
		}
	}
	// 文本只借它来触发回调，内容不留，光标也回到末尾。
	textField.text = @" ";
	return NO;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
	[self sendKeycode:28];
	return NO;
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
	// 软键盘收起后把第一响应者还给本视图，硬件键盘继续可用。
	[self becomeFirstResponder];
}

/// 底部一排单键。没有外接键盘时，安装器全靠这几个键走完流程。
- (void)buildKeys {
	NSArray<NSArray *> *specs = @[
		@[ @"Esc", @1 ], @[ @"Tab", @15 ], @[ @"←", @105 ], @[ @"↑", @103 ],
		@[ @"↓", @108 ], @[ @"→", @106 ], @[ @"⏎", @28 ], @[ @"⌫", @14 ],
	];
	UIStackView *row = [[UIStackView alloc] init];
	row.translatesAutoresizingMaskIntoConstraints = NO;
	row.axis = UILayoutConstraintAxisHorizontal;
	row.distribution = UIStackViewDistributionFillEqually;
	row.spacing = 6.0;
	[self addSubview:row];

	[NSLayoutConstraint activateConstraints:@[
		[row.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:8.0],
		[row.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8.0],
		[row.topAnchor constraintEqualToAnchor:self.topAnchor constant:4.0],
		[row.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-4.0],
	]];

	for (NSArray *spec in specs) {
		UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
		[button setTitle:spec[0] forState:UIControlStateNormal];
		button.titleLabel.font = [UIFont monospacedSystemFontOfSize:14.0 weight:UIFontWeightMedium];
		[button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
		button.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
		button.layer.cornerRadius = 6.0;
		button.tag = [spec[1] integerValue];
		[button addTarget:self action:@selector(keyTapped:) forControlEvents:UIControlEventTouchUpInside];
		[row addArrangedSubview:button];
	}
}

#pragma mark - 发送

- (void)sendKeycode:(uint16_t)keycode {
	if (keycode == 0) {
		return;
	}
	VLLinuxVirtualMachine *machine = self.machine;
	NSString *text = VLTextForSpecialKeycode(keycode);
	if (text.length > 0) {
		[machine sendText:text];
	}
	[machine sendKeycode:keycode pressed:YES];
	[machine sendKeycode:keycode pressed:NO];
}

- (void)sendCharacter:(unichar)character {
	BOOL needsShift = NO;
	uint16_t keycode = VLKeycodeForCharacter(character, &needsShift);
	if (keycode == 0) {
		return;
	}
	VLLinuxVirtualMachine *machine = self.machine;
	// 串口控制台这条路收的是字符，不是按键码，所以按原样再送一份。
	[machine sendText:[NSString stringWithFormat:@"%C", character]];
	// 只发 evdev 那一路，客户机既能在 tty 上收到字节，也能在图形界面里收到按键。
	if (needsShift) {
		[machine sendKeycode:42 pressed:YES];
	}
	[machine sendKeycode:keycode pressed:YES];
	[machine sendKeycode:keycode pressed:NO];
	if (needsShift) {
		[machine sendKeycode:42 pressed:NO];
	}
}

- (void)keyTapped:(UIButton *)sender {
	// 点完按钮把第一响应者抢回来，否则外接键盘的按键会断。
	[self becomeFirstResponder];
	[self sendKeycode:(uint16_t)sender.tag];
}

#pragma mark - 硬件键盘

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
	BOOL consumed = NO;
	for (UIPress *press in presses) {
		UIKey *key = press.key;
		if (key == nil) {
			continue;
		}
		consumed = YES;
		// 先按 HID 用法号查特殊键。不能先看 characters：UIKit 对方向键返回的是
		// "UIKeyInputUpArrow" 这类常量字符串，当成普通文本打进串口就是一堆洋字。
		uint16_t keycode = VLKeycodeForHIDUsage((uint16_t)key.keyCode);
		if (keycode != 0) {
			self.pressedKeys[@(key.keyCode)] = @(keycode);
			[self sendKeycode:keycode];
			continue;
		}
		NSString *characters = key.characters;
		if (characters.length == 0) {
			continue;
		}
		// 退格、回车这类控制字符也走按键码，否则会被当成不可打印字符丢掉。
		if (characters.length == 1) {
			uint16_t control = VLKeycodeForControlCharacter([characters characterAtIndex:0]);
			if (control != 0) {
				[self sendKeycode:control];
				continue;
			}
		}
		for (NSUInteger index = 0; index < characters.length; index++) {
			unichar character = [characters characterAtIndex:index];
			if (character >= 0x20 && character != 0x7F) {
				[self sendCharacter:character];
			}
		}
	}
	if (!consumed) {
		[super pressesBegan:presses withEvent:event];
	}
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
	BOOL consumed = NO;
	for (UIPress *press in presses) {
		UIKey *key = press.key;
		if (key == nil) {
			continue;
		}
		NSNumber *keycode = self.pressedKeys[@(key.keyCode)];
		if (keycode == nil) {
			continue;
		}
		consumed = YES;
		[self.pressedKeys removeObjectForKey:@(key.keyCode)];
		[self.machine sendKeycode:(uint16_t)keycode.unsignedShortValue pressed:NO];
	}
	if (!consumed) {
		[super pressesEnded:presses withEvent:event];
	}
}

- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
	[self pressesEnded:presses withEvent:event];
}

@end
