#import "VLSettingsViewController.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "VLHostCapabilities.h"
#import "VLLog.h"
#import "VLStartupLog.h"
#import "VLStorageManager.h"

static NSString *const VLSettingsRepositoryURL = @"https://github.com/twoyears666/virtual-linux-on-ipad";

typedef NS_ENUM(NSInteger, VLSettingsSection) {
	VLSettingsSectionAbout = 0,
	VLSettingsSectionStorage,
	VLSettingsSectionLog,
	VLSettingsSectionEnvironment,
	VLSettingsSectionCount,
};

@interface VLSettingsViewController () <UIDocumentPickerDelegate>

@end

@implementation VLSettingsViewController

- (instancetype)init {
	return [self initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
	[super viewDidLoad];

	self.title = @"设置";
	self.navigationItem.rightBarButtonItem =
		[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
													  target:self
													  action:@selector(doneTapped)];
	self.tableView.rowHeight = UITableViewAutomaticDimension;
	self.tableView.estimatedRowHeight = 56.0;
}

- (void)doneTapped {
	[self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - 数据源

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
	return VLSettingsSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	switch ((VLSettingsSection)section) {
		case VLSettingsSectionAbout:
			return 3;
		case VLSettingsSectionStorage:
			return (NSInteger)VLStorageManager.sharedManager.locations.count + 1;
		case VLSettingsSectionLog:
			return 1;
		case VLSettingsSectionEnvironment:
			return 1;
		default:
			return 0;
	}
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
	switch ((VLSettingsSection)section) {
		case VLSettingsSectionAbout:
			return @"关于";
		case VLSettingsSectionStorage:
			return @"存储位置";
		case VLSettingsSectionLog:
			return @"日志";
		case VLSettingsSectionEnvironment:
			return @"运行环境";
		default:
			return nil;
	}
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
	if ((VLSettingsSection)section == VLSettingsSectionStorage) {
		return @"新建虚拟机时可选择装到哪个位置；位置目录丢失时，其下的虚拟机会被冻结，直到目录重新可用。";
	}
	return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
												  reuseIdentifier:nil];
	cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
	cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
	cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
	cell.detailTextLabel.numberOfLines = 0;
	cell.selectionStyle = UITableViewCellSelectionStyleDefault;

	switch ((VLSettingsSection)indexPath.section) {
		case VLSettingsSectionAbout:
			cell.selectionStyle = UITableViewCellSelectionStyleNone;
			if (indexPath.row == 0) {
				cell.textLabel.text = @"版本";
				cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ (%@)",
					[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?",
					[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?"];
			} else if (indexPath.row == 1) {
				cell.textLabel.text = @"项目仓库";
				cell.detailTextLabel.text = VLSettingsRepositoryURL;
				cell.detailTextLabel.textColor = UIColor.systemBlueColor;
			} else {
				cell.textLabel.text = @"赞助";
				cell.detailTextLabel.text = @"链接稍后补充";
			}
			break;

		case VLSettingsSectionStorage: {
			NSArray<VLStorageLocation *> *locations = VLStorageManager.sharedManager.locations;
			if (indexPath.row < (NSInteger)locations.count) {
				VLStorageLocation *location = locations[(NSUInteger)indexPath.row];
				cell.textLabel.text = location.name;
				if (location.isBuiltIn) {
					cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · 内置", location.path];
				} else {
					cell.detailTextLabel.text = location.isAvailable
						? location.path
						: [NSString stringWithFormat:@"%@ · 不可用", location.path];
				}
				cell.detailTextLabel.textColor = location.isAvailable
					? UIColor.secondaryLabelColor
					: UIColor.systemOrangeColor;
				cell.selectionStyle = UITableViewCellSelectionStyleNone;
			} else {
				cell.textLabel.text = @"添加存储位置…";
				cell.textLabel.textColor = UIColor.systemBlueColor;
				cell.detailTextLabel.text = @"选一个文件夹（可在外接磁盘上）";
			}
			break;
		}

		case VLSettingsSectionLog: {
			cell.textLabel.text = @"导出日志";
			NSString *logPath = [VLLog logFilePath];
			NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:logPath error:NULL];
			unsigned long long size = [attributes[NSFileSize] unsignedLongLongValue];
			// 显示去掉 /var/mobile 前缀后的路径，一眼能对上「文件」App 里的 Media 目录。
			NSString *displayPath = [logPath hasPrefix:@"/var/mobile/"]
				? [logPath substringFromIndex:@"/var/mobile/".length]
				: logPath;
			cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %.1f KB",
										  displayPath,
										  (double)size / 1024.0];
			cell.textLabel.textColor = UIColor.systemBlueColor;
			break;
		}

		case VLSettingsSectionEnvironment:
			cell.textLabel.font = [UIFont monospacedSystemFontOfSize:12.0 weight:UIFontWeightRegular];
			cell.textLabel.numberOfLines = 0;
			cell.textLabel.text = [VLHostCapabilities diagnosticReport];
			cell.selectionStyle = UITableViewCellSelectionStyleNone;
			break;

		default:
			break;
	}

	return cell;
}

#pragma mark - 交互

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];

	if ((VLSettingsSection)indexPath.section == VLSettingsSectionAbout && indexPath.row == 1) {
		NSURL *url = [NSURL URLWithString:VLSettingsRepositoryURL];
		[UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
		return;
	}

	if ((VLSettingsSection)indexPath.section == VLSettingsSectionAbout && indexPath.row == 2) {
		UIAlertController *alert =
			[UIAlertController alertControllerWithTitle:@"赞助"
												message:@"赞助链接还没放，等有了会加在这里。"
										 preferredStyle:UIAlertControllerStyleAlert];
		[alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
		[self presentViewController:alert animated:YES completion:nil];
		return;
	}

	if ((VLSettingsSection)indexPath.section == VLSettingsSectionStorage) {
		NSArray<VLStorageLocation *> *locations = VLStorageManager.sharedManager.locations;
		if (indexPath.row >= (NSInteger)locations.count) {
			[self addStorageLocation];
		}
		return;
	}

	if ((VLSettingsSection)indexPath.section == VLSettingsSectionLog && indexPath.row == 0) {
		[self exportLog];
	}
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
	trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
	if ((VLSettingsSection)indexPath.section != VLSettingsSectionStorage) {
		return nil;
	}
	NSArray<VLStorageLocation *> *locations = VLStorageManager.sharedManager.locations;
	if (indexPath.row >= (NSInteger)locations.count) {
		return nil;
	}

	VLStorageLocation *location = locations[(NSUInteger)indexPath.row];
	if (location.isBuiltIn) {
		return nil;
	}

	UIContextualAction *removeAction =
		[UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
												title:@"移除"
											  handler:^(UIContextualAction *action,
														UIView *sourceView,
														void (^completionHandler)(BOOL)) {
		[VLStorageManager.sharedManager removeLocation:location];
		[self.tableView reloadRowsAtIndexPaths:@[ indexPath ]
							  withRowAnimation:UITableViewRowAnimationAutomatic];
		completionHandler(YES);
	}];
	return [UISwipeActionsConfiguration configurationWithActions:@[ removeAction ]];
}

#pragma mark - 添加位置 / 导出日志

- (void)addStorageLocation {
	UIDocumentPickerViewController *picker =
		[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeFolder ]
																   asCopy:NO];
	picker.delegate = self;
	picker.allowsMultipleSelection = NO;
	[self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
  didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
	NSURL *url = urls.firstObject;
	if (url == nil) {
		return;
	}

	NSError *error = nil;
	VLStorageLocation *location = [VLStorageManager.sharedManager addLocationWithURL:url error:&error];
	if (location == nil) {
		UIAlertController *alert =
			[UIAlertController alertControllerWithTitle:@"添加失败"
												message:error.localizedDescription ?: @"这个文件夹不能用"
										 preferredStyle:UIAlertControllerStyleAlert];
		[alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
		[self presentViewController:alert animated:YES completion:nil];
		return;
	}

	[VLStartupLog log:@"设置页添加存储位置：%@", location.path];
	[self.tableView reloadData];
}

- (void)exportLog {
	NSURL *reportURL = [VLLog exportReportURL];
	if (reportURL == nil) {
		UIAlertController *alert =
			[UIAlertController alertControllerWithTitle:@"导出失败"
												message:[NSString stringWithFormat:@"日志文件写不出来，可以到「文件」App 的 Media 目录下找：%@",
																				   [VLLog logsDirectoryPath]]
										 preferredStyle:UIAlertControllerStyleAlert];
		[alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
		[self presentViewController:alert animated:YES completion:nil];
		return;
	}

	UIActivityViewController *activity =
		[[UIActivityViewController alloc] initWithActivityItems:@[ reportURL ] applicationActivities:nil];
	activity.popoverPresentationController.sourceView = self.tableView;
	activity.popoverPresentationController.sourceRect =
		[self.tableView rectForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:VLSettingsSectionLog]];
	[self presentViewController:activity animated:YES completion:nil];
}

@end
