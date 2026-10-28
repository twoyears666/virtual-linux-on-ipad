#import "VLKeyboardInput.h"

#import "VLLinuxVirtualMachine.h"

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

@interface VLKeyboardInput () <UITextFieldDelegate>

@property (nonatomic, strong) UITextField *field;

@end

@implementation VLKeyboardInput

- (instancetype)initWithMachine:(VLLinuxVirtualMachine *)machine {
	self = [super init];
	if (self) {
		_machine = machine;
	}
	return self;
}

- (UITextField *)field {
	if (_field == nil) {
		UITextField *field = [[UITextField alloc] init];
		field.delegate = self;
		field.autocorrectionType = UITextAutocorrectionTypeNo;
		field.autocapitalizationType = UITextAutocapitalizationTypeNone;
		field.spellCheckingType = UITextSpellCheckingTypeNo;
		field.keyboardType = UIKeyboardTypeASCIICapable;
		field.inputAccessoryView = [self accessoryView];
		// 必须留在视图层级里才能成为第一响应者，但不要被看见。
		field.frame = CGRectMake(0.0, 0.0, 1.0, 1.0);
		field.alpha = 0.01;
		field.text = @"";
		_field = field;
	}
	return _field;
}

- (void)attachToView:(UIView *)view {
	if (view == nil) {
		return;
	}
	UITextField *field = self.field;
	if (field.superview == view) {
		return;
	}
	[field removeFromSuperview];
	[view addSubview:field];
}

- (void)show {
	[self.field becomeFirstResponder];
}

- (void)hide {
	[self.field resignFirstResponder];
}

- (BOOL)isVisible {
	return self.field.isFirstResponder;
}

/// 键盘上方那条功能键：Esc / Tab / 方向键 / 回车。
- (UIView *)accessoryView {
	UIToolbar *toolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0.0, 0.0, 0.0, 44.0)];
	NSArray<NSArray *> *specs = @[
		@[ @"Esc", @1 ], @[ @"Tab", @15 ],
		@[ @"←", @105 ], @[ @"↑", @103 ], @[ @"↓", @108 ], @[ @"→", @106 ],
		@[ @"回车", @28 ],
	];
	NSMutableArray<UIBarButtonItem *> *items = [NSMutableArray array];
	for (NSArray *spec in specs) {
		UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithTitle:spec[0]
																 style:UIBarButtonItemStylePlain
																target:self
																action:@selector(accessoryKeyTapped:)];
		item.tag = [spec[1] integerValue];
		[items addObject:item];
	}
	toolbar.items = items;
	[toolbar sizeToFit];
	return toolbar;
}

- (void)accessoryKeyTapped:(UIBarButtonItem *)sender {
	[self sendKeycode:(uint16_t)sender.tag];
	// 按完工具条按钮键盘会想收起，这里把焦点抢回来。
	[self.field becomeFirstResponder];
}

- (void)sendKeycode:(uint16_t)keycode {
	if (keycode == 0) {
		return;
	}
	VLLinuxVirtualMachine *machine = self.machine;
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
	if (needsShift) {
		[machine sendKeycode:42 pressed:YES];
	}
	[machine sendKeycode:keycode pressed:YES];
	[machine sendKeycode:keycode pressed:NO];
	if (needsShift) {
		[machine sendKeycode:42 pressed:NO];
	}
}

#pragma mark - UITextFieldDelegate

- (BOOL)textField:(UITextField *)textField
	shouldChangeCharactersInRange:(NSRange)range
				replacementString:(NSString *)string {
	if (string.length == 0) {
		// 系统键盘的退格键表现为「替换成空串」。
		[self sendKeycode:14];
		return NO;
	}
	for (NSUInteger index = 0; index < string.length; index++) {
		[self sendCharacter:[string characterAtIndex:index]];
	}
	// 输入框只当管道用，不留文字。
	textField.text = @"";
	return NO;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
	[self sendKeycode:28];
	textField.text = @"";
	return NO;
}

@end
