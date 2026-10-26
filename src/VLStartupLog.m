#import "VLStartupLog.h"

#import <UIKit/UIKit.h>

#import "VLLog.h"

#import <limits.h>
#import <signal.h>
#import <stdarg.h>
#import <stdio.h>
#import <unistd.h>
#import <fcntl.h>

static char VLStartupLogCrashPath[PATH_MAX];

static NSString *VLStartupLogDirectory(void) {
	NSArray<NSString *> *paths =
		NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
	NSString *directory = paths.firstObject;
	if (directory.length == 0) {
		directory = NSTemporaryDirectory();
	}
	return directory;
}

// 追加一行到 Documents/<fileName>。写日志本身失败不能影响主流程。
static void VLStartupLogAppend(NSString *fileName, NSString *line) {
	NSString *path = [VLStartupLogDirectory() stringByAppendingPathComponent:fileName];

	NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
	formatter.dateFormat = @"HH:mm:ss.SSS";
	NSString *stamped =
		[NSString stringWithFormat:@"[%@] %@\n", [formatter stringFromDate:[NSDate date]], line];

	NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
	if (handle == nil) {
		[stamped writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
		return;
	}

	@try {
		[handle seekToEndOfFile];
		[handle writeData:[stamped dataUsingEncoding:NSUTF8StringEncoding]];
	} @catch (NSException *exception) {
		// 忽略写入失败
	} @finally {
		[handle closeFile];
	}
}

static void VLStartupLogHandleException(NSException *exception) {
	NSString *report = [NSString stringWithFormat:
		@"未捕获异常\nname=%@\nreason=%@\ncallStackSymbols:\n%@",
		exception.name,
		exception.reason ?: @"(nil)",
		[exception.callStackSymbols componentsJoinedByString:@"\n"]];
	VLStartupLogAppend(@"crash.txt", report);
}

// 信号处理里只能用异步信号安全函数，因此直接 write(2) 到预先算好的路径。
static void VLStartupLogHandleSignal(int signalNumber) {
	const char *name = "signal";
	switch (signalNumber) {
		case SIGABRT: name = "SIGABRT"; break;
		case SIGSEGV: name = "SIGSEGV"; break;
		case SIGBUS: name = "SIGBUS"; break;
		case SIGILL: name = "SIGILL"; break;
		case SIGFPE: name = "SIGFPE"; break;
		default: break;
	}

	char buffer[256];
	int length = snprintf(buffer, sizeof(buffer), "\n[signal] %s (%d)\n", name, signalNumber);
	if (length > 0 && VLStartupLogCrashPath[0] != '\0') {
		int fd = open(VLStartupLogCrashPath, O_WRONLY | O_APPEND);
		if (fd >= 0) {
			ssize_t written = write(fd, buffer, (size_t)length);
			(void)written;
			close(fd);
		}
	}

	// 恢复默认行为后重新抛出，让系统仍生成原生崩溃报告
	signal(signalNumber, SIG_DFL);
	raise(signalNumber);
}

@implementation VLStartupLog

+ (void)installExceptionHandlers {
	NSString *crashPath = [VLStartupLogDirectory() stringByAppendingPathComponent:@"crash.txt"];
	[crashPath getFileSystemRepresentation:VLStartupLogCrashPath
								 maxLength:sizeof(VLStartupLogCrashPath)];

	NSSetUncaughtExceptionHandler(&VLStartupLogHandleException);

	int signals[] = { SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE };
	for (size_t index = 0; index < sizeof(signals) / sizeof(signals[0]); index++) {
		signal(signals[index], &VLStartupLogHandleSignal);
	}

	[self log:@"==== 启动开始 ===="];
	[self log:@"bundle=%@ path=%@", NSBundle.mainBundle.bundleIdentifier, NSBundle.mainBundle.bundlePath];
	[self log:@"系统=%@ 机型=%@", UIDevice.currentDevice.systemVersion, UIDevice.currentDevice.model];
}

+ (void)log:(NSString *)format, ... {
	va_list arguments;
	va_start(arguments, format);
	NSString *line = [[NSString alloc] initWithFormat:format arguments:arguments];
	va_end(arguments);

	VLStartupLogAppend(@"startup.log", line);
	// 同一行也进统一日志，导出时能在一份文件里看到完整时间线。
	[VLLog writeLine:line];
}

@end
