#import "VLISOInstaller.h"

#import <string.h>

#import "VLStartupLog.h"

static const uint32_t VLISOSectorSize = 2048;
static const uint32_t VLISOPrimaryVolumeDescriptorSector = 16;
static const uint32_t VLISOExtensionCacheSize = 1u << 20;

@implementation VLISOInstallResult
@end

#pragma mark - ISO9660 基础读取

static uint32_t VLISOReadUInt32LE(const uint8_t *bytes) {
	return (uint32_t)bytes[0] |
		((uint32_t)bytes[1] << 8) |
		((uint32_t)bytes[2] << 16) |
		((uint32_t)bytes[3] << 24);
}

/// 把目录记录解析成字典：name / extent / size / directory。
/// 根目录记录的名字是 0x00，所以这里不筛名字。
static NSDictionary *VLISOParseRecord(const uint8_t *record) {
	uint32_t extent = VLISOReadUInt32LE(record + 2);
	uint32_t size = VLISOReadUInt32LE(record + 10);
	BOOL isDirectory = (record[25] & 0x02) != 0;

	uint8_t nameLength = record[32];
	char name[256] = {0};
	// 名字最长 255 字节，缓冲区留一个字节给结尾的 0。
	if (nameLength > 0) {
		memcpy(name, record + 33, nameLength);
	}

	// ISO9660 的文件名带 ";1" 版本号，去掉。
	char *semicolon = strchr(name, ';');
	if (semicolon != NULL) {
		*semicolon = '\0';
	}

	return @{
		@"name": [NSString stringWithUTF8String:name] ?: @"",
		@"extent": @(extent),
		@"size": @(size),
		@"directory": @(isDirectory),
	};
}

/// 读主卷描述符，取根目录记录；不是 ISO9660 时返回 nil。
static NSDictionary *VLISOReadRootDirectory(NSFileHandle *handle) {
	[handle seekToFileOffset:(unsigned long long)VLISOPrimaryVolumeDescriptorSector * VLISOSectorSize];
	NSData *descriptor = [handle readDataOfLength:VLISOSectorSize];
	if (descriptor.length < VLISOSectorSize) {
		return nil;
	}

	const uint8_t *bytes = descriptor.bytes;
	if (memcmp(bytes + 1, "CD001", 5) != 0) {
		return nil;
	}
	// 卷描述符类型：1 = 主卷描述符。有些混合镜像第一张就是它。
	if (bytes[0] != 1) {
		return nil;
	}

	// 根目录记录固定在 156 偏移处，长度 34 字节。
	return VLISOParseRecord(bytes + 156);
}

static NSArray<NSDictionary *> *VLISOListDirectory(NSFileHandle *handle, uint32_t extent, uint32_t size) {
	NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
	if (size == 0) {
		return entries;
	}

	[handle seekToFileOffset:(unsigned long long)extent * VLISOSectorSize];
	NSData *data = [handle readDataOfLength:size];
	const uint8_t *bytes = data.bytes;
	NSUInteger offset = 0;

	while (offset < data.length) {
		uint8_t recordLength = bytes[offset];
		if (recordLength == 0) {
			// 记录不跨扇区，遇到 0 就跳到下一个扇区开头。
			offset = ((offset / VLISOSectorSize) + 1) * VLISOSectorSize;
			continue;
		}
		if (offset + recordLength > data.length) {
			break;
		}

		// 名字首字节 0x00 是 "."，0x01 是 ".."，跳过。
		uint8_t firstNameByte = bytes[offset + 33];
		if (firstNameByte == 0x00 || firstNameByte == 0x01) {
			offset += recordLength;
			continue;
		}

		NSDictionary *entry = VLISOParseRecord(bytes + offset);
		if (entry != nil) {
			[entries addObject:entry];
		}
		offset += recordLength;
	}

	return entries;
}

static NSDictionary *VLISOFindEntry(NSArray<NSDictionary *> *entries, NSString *name) {
	for (NSDictionary *entry in entries) {
		NSString *entryName = entry[@"name"];
		if ([entryName caseInsensitiveCompare:name] == NSOrderedSame) {
			return entry;
		}
	}
	return nil;
}

static NSDictionary *VLISOLookupPath(NSFileHandle *handle, NSDictionary *root, NSString *path) {
	NSDictionary *current = root;
	for (NSString *component in [path componentsSeparatedByString:@"/"]) {
		if (component.length == 0) {
			continue;
		}
		if (![current[@"directory"] boolValue]) {
			return nil;
		}
		NSArray<NSDictionary *> *entries =
			VLISOListDirectory(handle, [current[@"extent"] unsignedIntValue], [current[@"size"] unsignedIntValue]);
		current = VLISOFindEntry(entries, component);
		if (current == nil) {
			return nil;
		}
	}
	return current;
}

static BOOL VLISOExtractFile(NSFileHandle *handle,
							 NSDictionary *entry,
							 NSString *destination,
							 NSError **error) {
	uint32_t remaining = [entry[@"size"] unsignedIntValue];
	uint64_t offset = (uint64_t)[entry[@"extent"] unsignedIntValue] * VLISOSectorSize;

	NSFileManager *fileManager = NSFileManager.defaultManager;
	[fileManager createDirectoryAtPath:[destination stringByDeletingLastPathComponent]
		   withIntermediateDirectories:YES
							attributes:nil
								 error:NULL];
	[fileManager createFileAtPath:destination contents:nil attributes:nil];

	NSFileHandle *output = [NSFileHandle fileHandleForWritingAtPath:destination];
	if (output == nil) {
		if (error != NULL) {
			*error = [NSError errorWithDomain:@"VirtualLinux.ISO"
										 code:10
									 userInfo:@{ NSLocalizedDescriptionKey : @"写不出抽取出来的文件" }];
		}
		return NO;
	}

	[handle seekToFileOffset:offset];
	while (remaining > 0) {
		uint32_t chunk = MIN(remaining, VLISOExtensionCacheSize);
		NSData *data = [handle readDataOfLength:chunk];
		if (data.length == 0) {
			[output closeFile];
			if (error != NULL) {
				*error = [NSError errorWithDomain:@"VirtualLinux.ISO"
											 code:11
										 userInfo:@{ NSLocalizedDescriptionKey : @"ISO 读取中断" }];
			}
			return NO;
		}
		[output writeData:data];
		remaining -= (uint32_t)data.length;
	}
	[output closeFile];
	return YES;
}

#pragma mark - preseed

/// Debian 系安装应答：只装最小系统 + ssh，磁盘固定装在 virtio 的 /dev/vda。
static NSString *VLISOPreseedContents(void) {
	return @""
		"# 由 Virtual Linux 自动生成：无交互安装到 /dev/vda，账号 virtual / virtual\n"
		"d-i debian-installer/locale string en_US\n"
		"d-i debian-installer/keymap select us\n"
		"d-i keyboard-configuration/xkb-keymap select us\n"
		"\n"
		"d-i netcfg/choose_interface select auto\n"
		"d-i netcfg/get_hostname string virtual-linux\n"
		"d-i netcfg/get_domain string localdomain\n"
		"d-i netcfg/wireless_wep string\n"
		"\n"
		"d-i mirror/country string manual\n"
		"d-i mirror/http/hostname string deb.debian.org\n"
		"d-i mirror/http/directory string /debian\n"
		"d-i mirror/http/proxy string\n"
		"\n"
		"d-i partman-auto/method string regular\n"
		"d-i partman-auto/disk string /dev/vda\n"
		"d-i partman-auto/choose_recipe select virtual-linux\n"
		// 第一块 512MB FAT 区专门放内核 / initrd / 内核命令行：App 不跑 UEFI 也不跑 GRUB，
		// 直接从这块 FAT 里读文件启动，所以分区布局必须固定、不用默认的 atomic 配方。
		"d-i partman-auto/expert_recipe string \\\n"
		"      virtual-linux :: \\\n"
		"              512 512 512 fat32 \\\n"
		"                      $primary{ } $bootable{ } \\\n"
		"                      method{ format } format{ } \\\n"
		"                      use_filesystem{ } filesystem{ vfat } \\\n"
		"                      mountpoint{ /boot/efi } \\\n"
		"              . \\\n"
		"              8 8 -1 ext4 \\\n"
		"                      $primary{ } \\\n"
		"                      method{ format } format{ } \\\n"
		"                      use_filesystem{ } filesystem{ ext4 } \\\n"
		"                      mountpoint{ / } \\\n"
		"              .\n"
		"d-i partman-partitioning/confirm_write_new_label boolean true\n"
		"d-i partman/choose_partition select finish\n"
		"d-i partman/confirm boolean true\n"
		"d-i partman/confirm_nooverwrite boolean true\n"
		"\n"
		"d-i clock-setup/utc boolean true\n"
		"d-i time/zone string UTC\n"
		"d-i clock-setup/ntp boolean true\n"
		"\n"
		"d-i passwd/root-login boolean true\n"
		"d-i passwd/root-password password virtual\n"
		"d-i passwd/root-password-again password virtual\n"
		"d-i passwd/user-fullname string Virtual\n"
		"d-i passwd/username string virtual\n"
		"d-i passwd/user-password password virtual\n"
		"d-i passwd/user-password-again password virtual\n"
		"\n"
		"tasksel tasksel/first multiselect standard, ssh-server\n"
		"d-i pkgsel/include string openssh-server\n"
		"popularity-contest popularity-contest/participate boolean false\n"
		"\n"
		// 不装引导程序：App 每次启动都自己从 /boot/efi 那块 FAT 区读内核与 initrd，
		// 客户机里既没有 UEFI 固件也没有 GRUB，让安装器去装引导反而会卡住。
		"d-i grub-installer/skip boolean true\n"
		"d-i lilo-installer/skip boolean true\n"
		// 安装收尾：把内核、initrd 和内核命令行复制到那块 FAT 区，供 App 启动时读取。
		"d-i preseed/late_command string \\\n"
		"      in-target cp /boot/vmlinuz-* /boot/efi/VMLINUZ ; \\\n"
		"      in-target cp /boot/initrd.img-* /boot/efi/INITRD ; \\\n"
		"      in-target sh -c 'rootdev=$(findmnt -no SOURCE /) ;"
		" echo \"root=PARTUUID=$(blkid -s PARTUUID -o value $rootdev)"
		" rw console=ttyAMA0,115200 earlycon=pl011,0x09000000 loglevel=7\" > /boot/efi/VLBOOT.CFG'\n"
		"d-i finish-install/reboot_in_progress note\n";
}

#pragma mark - 主流程

@implementation VLISOInstaller

+ (VLISOInstallResult *)prepareISOAtPath:(NSString *)isoPath
						machineDirectory:(NSURL *)machineDirectory
					   distroIdentifier:(NSString *)distroIdentifier
								  error:(NSError **)error {
	NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:isoPath];
	if (handle == nil) {
		if (error != NULL) {
			*error = [NSError errorWithDomain:@"VirtualLinux.ISO"
										 code:1
									 userInfo:@{ NSLocalizedDescriptionKey : @"打不开 ISO 文件" }];
		}
		return nil;
	}

	NSDictionary *root = VLISOReadRootDirectory(handle);
	if (root == nil) {
		[handle closeFile];
		if (error != NULL) {
			*error = [NSError errorWithDomain:@"VirtualLinux.ISO"
										 code:2
									 userInfo:@{ NSLocalizedDescriptionKey :
										 @"这个 ISO 不是标准 ISO9660 安装盘（目前只解析 Debian / Ubuntu 系）" }];
		}
		return nil;
	}

	// Debian 系的安装目录优先级：arm64 → amd64 → 通用 → i386；再兜底 casper（Ubuntu）与 boot。
	NSArray<NSArray<NSString *> *> *candidates = @[
		@[ @"install.a64", @"debian" ],
		@[ @"install.arm64", @"debian" ],
		@[ @"install.amd", @"debian" ],
		@[ @"install", @"debian" ],
		@[ @"install.386", @"debian" ],
		@[ @"casper", @"ubuntu" ],
		@[ @"boot", @"linux" ],
		@[ @"isolinux", @"linux" ],
	];

	NSDictionary *kernelEntry = nil;
	NSDictionary *initrdEntry = nil;
	NSString *family = @"unknown";

	for (NSArray<NSString *> *candidate in candidates) {
		NSDictionary *directoryEntry = VLISOLookupPath(handle, root, candidate[0]);
		if (directoryEntry == nil || ![directoryEntry[@"directory"] boolValue]) {
			continue;
		}

		NSArray<NSDictionary *> *children =
			VLISOListDirectory(handle, [directoryEntry[@"extent"] unsignedIntValue],
							   [directoryEntry[@"size"] unsignedIntValue]);
		NSDictionary *foundKernel = nil;
		NSDictionary *foundInitrd = nil;
		for (NSDictionary *child in children) {
			if ([child[@"directory"] boolValue]) {
				continue;
			}
			NSString *name = [child[@"name"] lowercaseString];
			if (foundKernel == nil && ([name hasPrefix:@"vmlinuz"] || [name hasPrefix:@"vmlinux"])) {
				foundKernel = child;
			} else if (foundInitrd == nil &&
					   ([name hasPrefix:@"initrd"] || [name hasPrefix:@"initramfs"])) {
				foundInitrd = child;
			}
		}

		if (foundKernel != nil && foundInitrd != nil) {
			kernelEntry = foundKernel;
			initrdEntry = foundInitrd;
			family = candidate[1];
			break;
		}
	}

	if (kernelEntry == nil) {
		[handle closeFile];
		if (error != NULL) {
			*error = [NSError errorWithDomain:@"VirtualLinux.ISO"
										 code:3
									 userInfo:@{ NSLocalizedDescriptionKey :
										 @"ISO 里找不到内核 / initrd（只支持 Debian 系 install 目录与 Ubuntu casper）" }];
		}
		return nil;
	}

	NSURL *bootDirectory = [machineDirectory URLByAppendingPathComponent:@"boot" isDirectory:YES];
	NSString *kernelPath =
		[[bootDirectory URLByAppendingPathComponent:@"vmlinuz"] path];
	NSString *initrdExtension = [initrdEntry[@"name"] pathExtension];
	if (initrdExtension.length == 0) {
		initrdExtension = @"gz";
	}
	NSString *initrdPath =
		[[bootDirectory URLByAppendingPathComponent:[NSString stringWithFormat:@"initrd.%@", initrdExtension]] path];

	if (!VLISOExtractFile(handle, kernelEntry, kernelPath, error) ||
		!VLISOExtractFile(handle, initrdEntry, initrdPath, error)) {
		[handle closeFile];
		return nil;
	}

	VLISOInstallResult *result = [[VLISOInstallResult alloc] init];
	result.family = family;
	result.kernelPath = kernelPath;
	result.initrdPath = initrdPath;

	if ([family isEqualToString:@"debian"]) {
		NSURL *autoInstallDirectory =
			[machineDirectory URLByAppendingPathComponent:@"autoinstall" isDirectory:YES];
		// 先建目录：直接用 writeToURL 会因为父目录不存在而失败。
		[NSFileManager.defaultManager createDirectoryAtURL:autoInstallDirectory
							   withIntermediateDirectories:YES
												attributes:nil
													 error:NULL];
		NSURL *preseedURL = [autoInstallDirectory URLByAppendingPathComponent:@"preseed.cfg"];
		NSError *writeError = nil;
		if ([VLISOPreseedContents() writeToURL:preseedURL
								   atomically:YES
									 encoding:NSUTF8StringEncoding
										error:&writeError]) {
			result.preseedPath = preseedURL.path;
		} else {
			[VLStartupLog log:@"preseed 写入失败：%@", writeError.localizedDescription];
		}
	}

	[handle closeFile];

	result.summary = result.preseedPath.length > 0
		? @"Debian 系安装盘 · 已抽取内核/initrd 并生成 preseed 自动应答"
		: [NSString stringWithFormat:@"已抽取内核/initrd（%@ 系，未生成自动应答）", family];

	[VLStartupLog log:@"ISO 解析：%@ → %@", isoPath.lastPathComponent, result.summary];
	return result;
}

@end
