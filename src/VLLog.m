#import "VLLog.h"

#import <UIKit/UIKit.h>
#import <sys/sysctl.h>

#import "VLHostCapabilities.h"
#import "VLStorageManager.h"

static NSString *const VLLogFolderName = @"logs";
static NSString *const VLLogFileName = @"app.log";
static const unsigned long long VLLogMaximumBytes = 512ULL * 1024ULL;

@implementation VLLog

+ (NSString *)logsDirectoryPath {
	// 日志跟着虚拟机目录走（/var/mobile/Media/VirtualMachines/logs），
	// 这样卸载重装、换签名都不会把排查现场一起删掉。
	NSString *root = VLStorageManager.sharedManager.defaultLocation.path;
	if (root.length == 0) {
		root = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
		if (root.length == 0) {
			root = NSTemporaryDirectory();
		}
	}
	NSString *directory = [root stringByAppendingPathComponent:VLLogFolderName];
	[NSFileManager.defaultManager createDirectoryAtPath:directory
							withIntermediateDirectories:YES
											 attributes:nil
												  error:NULL];
	return directory;
}

+ (NSString *)logFilePath {
	return [[self logsDirectoryPath] stringByAppendingPathComponent:VLLogFileName];
}

+ (void)start {
	NSString *path = [self logFilePath];
	if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
		[NSFileManager.defaultManager createFileAtPath:path contents:nil attributes:nil];
	}
}

+ (void)rotateIfNeeded {
	NSString *path = [self logFilePath];
	NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL];
	if (attributes == nil || [attributes[NSFileType] isEqual:NSFileTypeDirectory]) {
		return;
	}
	if ([attributes[NSFileSize] unsignedLongLongValue] < VLLogMaximumBytes) {
		return;
	}

	NSString *rotated = [[self logsDirectoryPath] stringByAppendingPathComponent:@"app.1.log"];
	[NSFileManager.defaultManager removeItemAtPath:rotated error:NULL];
	[NSFileManager.defaultManager moveItemAtPath:path toPath:rotated error:NULL];
	[NSFileManager.defaultManager createFileAtPath:path contents:nil attributes:nil];
}

+ (void)writeLine:(NSString *)line {
	if (line == nil) {
		return;
	}

	NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
	formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
	NSString *stamped = [NSString stringWithFormat:@"[%@] %@\n",
												  [formatter stringFromDate:[NSDate date]],
												  line];

	[self rotateIfNeeded];

	NSString *path = [self logFilePath];
	NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
	if (handle == nil) {
		[stamped writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
		return;
	}

	@try {
		[handle seekToEndOfFile];
		[handle writeData:[stamped dataUsingEncoding:NSUTF8StringEncoding]];
	} @catch (NSException *exception) {
		// 日志写失败不能影响主流程
	} @finally {
		[handle closeFile];
	}
}

+ (void)log:(NSString *)format, ... {
	va_list arguments;
	va_start(arguments, format);
	NSString *line = [[NSString alloc] initWithFormat:format arguments:arguments];
	va_end(arguments);
	[self writeLine:line];
}

#pragma mark - 导出

+ (NSString *)contentsOfFileAtPath:(NSString *)path {
	return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL] ?: @"";
}

+ (NSURL *)exportReportURL {
	NSMutableString *report = [NSMutableString string];

	[report appendString:@"===== Virtual Linux 日志导出 =====\n"];
	[report appendFormat:@"导出时间：%@\n", [NSDate date]];
	[report appendFormat:@"系统：iOS %@\n", UIDevice.currentDevice.systemVersion];
	[report appendFormat:@"机型：%@\n", UIDevice.currentDevice.model];
	[report appendFormat:@"应用版本：%@ (%@)\n",
		[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?",
		[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?"];
	[report appendFormat:@"\n----- 运行环境 -----\n%@\n", [VLHostCapabilities diagnosticReport]];

	NSMutableString *storage = [NSMutableString string];
	for (VLStorageLocation *location in VLStorageManager.sharedManager.locations) {
		[storage appendFormat:@"%@：%@（%@）\n",
			location.name,
			location.path,
			location.isAvailable ? @"可用" : @"不可用/已冻结"];
	}
	[report appendFormat:@"\n----- 存储位置 -----\n%@", storage];

	NSArray<NSArray<NSString *> *> *appended = @[
		@[ @"统一日志", [self logFilePath] ],
		@[ @"统一日志（上一次轮转）", [[self logsDirectoryPath] stringByAppendingPathComponent:@"app.1.log"] ],
		@[ @"启动埋点", [[self logsDirectoryPath] stringByAppendingPathComponent:@"startup.log"] ],
		@[ @"崩溃记录", [[self logsDirectoryPath] stringByAppendingPathComponent:@"crash.txt"] ],
	];

	for (NSArray<NSString *> *entry in appended) {
		NSString *path = entry[1];
		NSString *contents = [self contentsOfFileAtPath:path];
		if (contents.length == 0) {
			contents = @"(空)\n";
		}
		[report appendFormat:@"\n===== %@（%@）=====\n%@", entry[0], path.lastPathComponent, contents];
	}

	NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
	formatter.dateFormat = @"yyyyMMdd-HHmmss";
	NSString *fileName = [NSString stringWithFormat:@"VirtualLinux-log-%@.txt",
						   [formatter stringFromDate:[NSDate date]]];
	NSURL *url = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
		URLByAppendingPathComponent:fileName];

	NSError *error = nil;
	if (![report writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
		[self log:@"日志导出失败：%@", error.localizedDescription];
		return nil;
	}
	[self log:@"日志已导出：%@", url.lastPathComponent];
	return url;
}

@end
