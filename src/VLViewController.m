#import "VLViewController.h"

#import "VLHostCapabilities.h"
#import "VLLinuxVirtualMachine.h"

@interface VLViewController ()

@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UITextView *logTextView;
@property (nonatomic, strong) VLLinuxVirtualMachine *virtualMachine;

@end

@implementation VLViewController

- (void)viewDidLoad {
	[super viewDidLoad];

	self.title = @"Virtual Linux";
	self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
	self.virtualMachine = [[VLLinuxVirtualMachine alloc] init];

	UIScrollView *scrollView = [[UIScrollView alloc] init];
	scrollView.translatesAutoresizingMaskIntoConstraints = NO;
	scrollView.alwaysBounceVertical = YES;
	[self.view addSubview:scrollView];

	UIStackView *stackView = [[UIStackView alloc] init];
	stackView.translatesAutoresizingMaskIntoConstraints = NO;
	stackView.axis = UILayoutConstraintAxisVertical;
	stackView.spacing = 16.0;
	[scrollView addSubview:stackView];

	[stackView addArrangedSubview:[self cardWithText:[VLHostCapabilities diagnosticReport]]];

	UIButton *startButton = [UIButton buttonWithType:UIButtonTypeSystem];
	startButton.translatesAutoresizingMaskIntoConstraints = NO;
	[startButton setTitle:@"启动 Linux 虚拟机" forState:UIControlStateNormal];
	startButton.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
	[startButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
	startButton.backgroundColor = self.view.tintColor;
	startButton.layer.cornerRadius = 12.0;
	[startButton addTarget:self action:@selector(startTapped) forControlEvents:UIControlEventTouchUpInside];
	[stackView addArrangedSubview:startButton];
	[startButton.heightAnchor constraintEqualToConstant:50.0].active = YES;

	self.statusLabel = [[UILabel alloc] init];
	self.statusLabel.numberOfLines = 0;
	self.statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
	self.statusLabel.textColor = UIColor.secondaryLabelColor;
	self.statusLabel.text = @"阶段：界面与 CI 已就绪，虚拟化后端待接入";
	[stackView addArrangedSubview:self.statusLabel];

	UILabel *logTitleLabel = [[UILabel alloc] init];
	logTitleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
	logTitleLabel.text = @"运行日志";
	[stackView addArrangedSubview:logTitleLabel];

	self.logTextView = [[UITextView alloc] init];
	self.logTextView.translatesAutoresizingMaskIntoConstraints = NO;
	self.logTextView.editable = NO;
	self.logTextView.selectable = YES;
	self.logTextView.font = [UIFont monospacedSystemFontOfSize:12.0 weight:UIFontWeightRegular];
	self.logTextView.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
	self.logTextView.layer.cornerRadius = 12.0;
	self.logTextView.textContainerInset = UIEdgeInsetsMake(12.0, 12.0, 12.0, 12.0);
	[stackView addArrangedSubview:self.logTextView];
	[self.logTextView.heightAnchor constraintEqualToConstant:240.0].active = YES;

	[NSLayoutConstraint activateConstraints:@[
		[scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
		[scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
		[scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
		[scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

		[stackView.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor constant:16.0],
		[stackView.leadingAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.leadingAnchor constant:16.0],
		[stackView.trailingAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.trailingAnchor constant:-16.0],
		[stackView.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor constant:-16.0],
	]];

	[self appendLog:@"已读取运行环境，可直接点按上方按钮查看启动结果。"];
}

- (UIView *)cardWithText:(NSString *)text {
	UIView *card = [[UIView alloc] init];
	card.translatesAutoresizingMaskIntoConstraints = NO;
	card.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
	card.layer.cornerRadius = 12.0;

	UILabel *label = [[UILabel alloc] init];
	label.translatesAutoresizingMaskIntoConstraints = NO;
	label.numberOfLines = 0;
	label.font = [UIFont systemFontOfSize:13.0];
	label.textColor = UIColor.labelColor;
	label.text = text;
	[card addSubview:label];

	[NSLayoutConstraint activateConstraints:@[
		[label.topAnchor constraintEqualToAnchor:card.topAnchor constant:16.0],
		[label.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16.0],
		[label.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16.0],
		[label.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16.0],
	]];

	return card;
}

- (void)startTapped {
	NSError *error = nil;
	if ([self.virtualMachine startWithError:&error]) {
		self.statusLabel.text = @"阶段：客户机启动中";
		[self appendLog:@"已发出启动请求。"];
		return;
	}

	self.statusLabel.text = [NSString stringWithFormat:@"阶段：启动被拒绝（错误码 %ld）", (long)error.code];
	[self appendLog:error.localizedDescription];
}

- (void)appendLog:(NSString *)message {
	NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
	formatter.dateFormat = @"HH:mm:ss";
	NSString *line = [NSString stringWithFormat:@"[%@] %@", [formatter stringFromDate:[NSDate date]], message];

	self.logTextView.text = self.logTextView.text.length > 0
		? [self.logTextView.text stringByAppendingFormat:@"\n%@", line]
		: line;

	if (self.logTextView.text.length > 1) {
		[self.logTextView scrollRangeToVisible:NSMakeRange(self.logTextView.text.length - 1, 1)];
	}
}

@end
