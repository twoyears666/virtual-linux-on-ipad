#import "VLHostCapabilities.h"

#import <dlfcn.h>
#import <mach/mach.h>
#import <os/proc.h>
#import <sys/sysctl.h>

static NSString *VLHardwareModel(void) {
	size_t size = 0;
	if (sysctlbyname("hw.machine", NULL, &size, NULL, 0) != 0 || size == 0) {
		return @"unknown";
	}

	char *value = calloc(1, size);
	if (value == NULL) {
		return @"unknown";
	}

	NSString *model = @"unknown";
	if (sysctlbyname("hw.machine", value, &size, NULL, 0) == 0) {
		model = [NSString stringWithUTF8String:value] ?: @"unknown";
	}
	free(value);
	return model;
}

/// 查找 Hypervisor 运行时。优先用 App 内自带的副本（从 macOS 抽取并重签），
/// 其次才看系统里是否存在同名库。
static void *VLHypervisorHandle(NSString **outPath) {
	static void *handle = NULL;
	static NSString *handlePath = nil;
	static dispatch_once_t onceToken;

	dispatch_once(&onceToken, ^{
		NSMutableArray<NSString *> *candidates = [NSMutableArray array];

		NSString *frameworksPath = NSBundle.mainBundle.privateFrameworksPath;
		if (frameworksPath.length > 0) {
			[candidates addObject:[frameworksPath stringByAppendingPathComponent:@"Hypervisor.framework/Hypervisor"]];
		}

		[candidates addObjectsFromArray:@[
			@"/var/jb/usr/lib/libHypervisor.dylib",
			@"/usr/lib/libHypervisor.dylib",
			@"/System/Library/Frameworks/Hypervisor.framework/Hypervisor",
			@"/System/Library/PrivateFrameworks/Hypervisor.framework/Hypervisor",
		]];

		for (NSString *candidate in candidates) {
			void *loaded = dlopen(candidate.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
			if (loaded == NULL) {
				continue;
			}
			if (dlsym(loaded, "hv_vm_create") != NULL) {
				handle = loaded;
				handlePath = candidate;
				return;
			}
			dlclose(loaded);
		}
	});

	if (outPath != NULL) {
		*outPath = handlePath;
	}
	return handle;
}

@implementation VLHostCapabilities

+ (NSString *)systemVersionString {
	NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
	return [NSString stringWithFormat:@"%ld.%ld.%ld",
			(long)version.majorVersion, (long)version.minorVersion, (long)version.patchVersion];
}

+ (BOOL)isSystemVersionSupported {
	NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
	if (version.majorVersion < 14) {
		return NO;
	}
	if (version.majorVersion > 16) {
		return NO;
	}
	// 16.4 起 XNU 移除了 Hypervisor 支持。
	if (version.majorVersion == 16 && version.minorVersion > 3) {
		return NO;
	}
	return YES;
}

+ (BOOL)isHypervisorUsable {
	return [self isSystemVersionSupported] && VLHypervisorHandle(NULL) != NULL;
}

+ (NSString *)hypervisorSource {
	NSString *path = nil;
	VLHypervisorHandle(&path);
	return path;
}

+ (NSString *)diagnosticReport {
	NSMutableArray<NSString *> *lines = [NSMutableArray array];

	[lines addObject:[NSString stringWithFormat:@"设备型号：%@", VLHardwareModel()]];
	[lines addObject:[NSString stringWithFormat:@"系统版本：iOS %@", [self systemVersionString]]];

	BOOL rootless = [NSFileManager.defaultManager fileExistsAtPath:@"/var/jb"];
	[lines addObject:[NSString stringWithFormat:@"越狱环境：%@", rootless ? @"rootless（/var/jb）" : @"未检测到 /var/jb"]];

	if (![self isSystemVersionSupported]) {
		NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
		NSString *reason = version.majorVersion > 16 || (version.majorVersion == 16 && version.minorVersion > 3)
			? @"16.4 起 XNU 移除了 Hypervisor 支持，本包只支持 14.0 – 16.3.1"
			: @"系统版本低于 14.0，不在支持范围内";
		[lines addObject:[NSString stringWithFormat:@"硬件虚拟化：不可用（%@）", reason]];
		return [lines componentsJoinedByString:@"\n"];
	}

	NSString *source = [self hypervisorSource];
	if (source.length > 0) {
		[lines addObject:[NSString stringWithFormat:@"硬件虚拟化：可用（Hypervisor 来自 %@）", source]];
	} else {
		[lines addObject:@"硬件虚拟化：系统版本支持，但未找到 Hypervisor 运行时"];
		[lines addObject:@"修复方式：把抽取并重签好的 Hypervisor.framework 放进 VirtualLinux.app/Frameworks/ 后重装"];
	}

	return [lines componentsJoinedByString:@"\n"];
}

+ (NSUInteger)physicalMemoryMB {
	return (NSUInteger)(NSProcessInfo.processInfo.physicalMemory / (1024ULL * 1024ULL));
}

+ (NSUInteger)availableMemoryMB {
	// os_proc_available_memory 给的是「本进程还能用多少」，没上限时返回 0，这时不猜。
	size_t available = os_proc_available_memory();
	return (NSUInteger)(available / (1024ULL * 1024ULL));
}

+ (NSUInteger)residentMemoryMB {
	mach_task_basic_info_data_t info;
	mach_count_t count = MACH_TASK_BASIC_INFO_COUNT;
	if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) {
		return 0;
	}
	return (NSUInteger)(info.resident_size / (1024ULL * 1024ULL));
}

+ (NSUInteger)maximumGuestMemoryMB {
	NSUInteger physical = [self physicalMemoryMB];
	if (physical < 1024) {
		return 512;
	}

	// 只给客机一半，并且至少给系统留 2 GB。留太少的话，前台大内存 App 会把
	// 后台服务（首当其冲是媒体服务）挤进 jetsam，症状就是全机没声音。
	NSUInteger half = physical / 2;
	NSUInteger withSystemReserve = physical > 2048 ? physical - 2048 : half;
	NSUInteger maximum = MIN(half, withSystemReserve);
	maximum -= maximum % 512;
	return MAX(maximum, 512);
}

@end
