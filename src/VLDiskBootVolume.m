#import "VLDiskBootVolume.h"

#import <ctype.h>
#import <stdlib.h>
#import <string.h>

#import "VLStartupLog.h"

// GPT 与 FAT 的布局都按 512 字节扇区写死在规范里，这里所有偏移都以「镜像内字节偏移」为单位。
static const uint32_t VLDiskBootSectorSize = 512;
// 分区项最多处理 128 个：GPT 规范里一屏分区项就是 128 个，多出来的不认。
static const uint32_t VLDiskBootMaxPartitions = 128;
// 单次读盘上限：系统盘是 16GB 稀疏镜像，绝不整盘读进内存，逐段读也收紧到这个上限。
static const NSUInteger VLDiskBootMaxReadLength = 1u << 20;
// 解析目录簇链时防止被坏盘绕成死循环。
static const uint32_t VLDiskBootMaxDirectoryClusters = 1u << 20;

static const uint32_t VLDiskBootFAT32EndOfChain = 0x0FFFFFF8;
static const uint32_t VLDiskBootFAT32BadCluster = 0x0FFFFFF7;
static const uint32_t VLDiskBootFAT16EndOfChain = 0xFFF8;
static const uint32_t VLDiskBootFAT16BadCluster = 0xFFF7;

#pragma mark - 小端整数读取

static uint16_t VLReadUInt16LE(const uint8_t *bytes) {
	return (uint16_t)((uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8));
}

static uint32_t VLReadUInt32LE(const uint8_t *bytes) {
	return (uint32_t)bytes[0]
		| ((uint32_t)bytes[1] << 8)
		| ((uint32_t)bytes[2] << 16)
		| ((uint32_t)bytes[3] << 24);
}

static uint64_t VLReadUInt64LE(const uint8_t *bytes) {
	return (uint64_t)VLReadUInt32LE(bytes) | ((uint64_t)VLReadUInt32LE(bytes + 4) << 32);
}

static NSError *VLDiskBootError(NSInteger code, NSString *description) {
	return [NSError errorWithDomain:@"VirtualLinux.DiskBoot"
							   code:code
						   userInfo:@{ NSLocalizedDescriptionKey : description }];
}

/// 定位到 offset 读 length 字节；长度不符（越界 / 短读）或底层报错都返回 nil，绝不崩。
static NSData *VLReadAtOffset(NSFileHandle *handle, uint64_t offset, NSUInteger length) {
	if (length == 0) {
		return [NSData data];
	}
	@try {
		[handle seekToFileOffset:(unsigned long long)offset];
	} @catch (NSException *exception) {
		(void)exception;
		return nil;
	}
	NSData *data = [handle readDataOfLength:length];
	if (data.length != length) {
		return nil;
	}
	return data;
}

#pragma mark - FAT 布局

typedef struct {
	uint64_t partitionStart;    // 分区在镜像里的起始字节
	uint16_t bytesPerSector;
	uint8_t sectorsPerCluster;
	uint32_t fatSize;           // FAT 表占多少个扇区
	uint64_t fatStart;          // FAT 表起始字节
	uint64_t rootDirectoryStart; // 根目录区起始字节（FAT16 的固定根目录就在这里）
	uint64_t dataStart;         // 数据区（簇 2）起始字节
	uint16_t rootEntryCount;    // FAT16 固定根目录的项数
	uint32_t rootCluster;       // FAT32 根目录起始簇
	BOOL isFAT32;
} VLFATLayout;

typedef struct {
	uint32_t firstCluster;
	uint32_t fileLength;
} VLDirEntry;

static BOOL VLIsPowerOfTwo(uint32_t value) {
	return value != 0 && (value & (value - 1)) == 0;
}

/// 按 BPB 校验一个分区是不是 FAT16/FAT32；是就填出布局。任一字段不合法都当它不是 FAT。
static BOOL VLFATParseLayout(NSFileHandle *handle, uint64_t partitionStart, VLFATLayout *outLayout) {
	NSData *bpbData = VLReadAtOffset(handle, partitionStart, VLDiskBootSectorSize);
	if (bpbData == nil) {
		return NO;
	}
	const uint8_t *bpb = bpbData.bytes;

	// 偏移 0 应为跳转指令，其余两种都不是合法 BPB。
	if (bpb[0] != 0xEB && bpb[0] != 0xE9) {
		return NO;
	}

	uint16_t bytesPerSector = VLReadUInt16LE(bpb + 11);
	if (bytesPerSector != 512 && bytesPerSector != 1024 && bytesPerSector != 2048 && bytesPerSector != 4096) {
		return NO;
	}
	uint8_t sectorsPerCluster = bpb[13];
	if (!VLIsPowerOfTwo(sectorsPerCluster)) {
		return NO;
	}
	if (VLReadUInt16LE(bpb + 14) < 1) {
		return NO;
	}
	if (VLReadUInt16LE(bpb + 16) < 1) {
		return NO;
	}
	uint32_t fatSize = VLReadUInt16LE(bpb + 22);
	if (fatSize == 0) {
		fatSize = VLReadUInt32LE(bpb + 36);
	}
	if (fatSize == 0) {
		return NO;
	}
	if (bpb[510] != 0x55 || bpb[511] != 0xAA) {
		return NO;
	}

	uint16_t rootEntryCount = VLReadUInt16LE(bpb + 17);
	BOOL isFAT32 = (rootEntryCount == 0);

	uint64_t fatStart = partitionStart + (uint64_t)VLReadUInt16LE(bpb + 14) * bytesPerSector;
	// FAT 表后面紧跟根目录区。FAT32 的根目录是一条簇链（起点在偏移 44），根目录区长度 0；
	// FAT16 的根目录是 rootEntryCount * 32 字节的固定区域，簇区必须从它后面才开始。
	uint64_t rootDirectoryStart = fatStart + (uint64_t)VLReadUInt16LE(bpb + 16) * fatSize * bytesPerSector;
	uint64_t dataStart = isFAT32 ? rootDirectoryStart : rootDirectoryStart + (uint64_t)rootEntryCount * 32;

	outLayout->partitionStart = partitionStart;
	outLayout->bytesPerSector = bytesPerSector;
	outLayout->sectorsPerCluster = sectorsPerCluster;
	outLayout->fatSize = fatSize;
	outLayout->fatStart = fatStart;
	outLayout->rootDirectoryStart = rootDirectoryStart;
	outLayout->dataStart = dataStart;
	outLayout->rootEntryCount = rootEntryCount;
	outLayout->isFAT32 = isFAT32;
	// FAT32 的根目录起点写在偏移 44，取低 28 位；FAT16 用不到它。
	outLayout->rootCluster = isFAT32 ? (VLReadUInt32LE(bpb + 44) & 0x0FFFFFFF) : 0;
	return YES;
}

/// 读簇 n 在 FAT 表里的下一簇编号；读不出返回 NO。
static BOOL VLFATNextCluster(NSFileHandle *handle, const VLFATLayout *layout, uint32_t cluster, uint32_t *outNext) {
	NSUInteger entrySize = layout->isFAT32 ? 4 : 2;
	NSData *data = VLReadAtOffset(handle, layout->fatStart + (uint64_t)cluster * entrySize, entrySize);
	if (data == nil) {
		return NO;
	}
	*outNext = layout->isFAT32 ? (VLReadUInt32LE(data.bytes) & 0x0FFFFFFF) : VLReadUInt16LE(data.bytes);
	return YES;
}

/// 值为 0、坏簇、以及结束标志都当作簇链终点。
static BOOL VLFATClusterIsEnd(const VLFATLayout *layout, uint32_t value) {
	if (value == 0 || value == 1) {
		return YES;
	}
	if (layout->isFAT32) {
		return value == VLDiskBootFAT32BadCluster || value >= VLDiskBootFAT32EndOfChain;
	}
	return value == VLDiskBootFAT16BadCluster || value >= VLDiskBootFAT16EndOfChain;
}

#pragma mark - 目录项

typedef NS_ENUM(NSInteger, VLEntryAction) {
	VLEntryActionContinue = 0,
	VLEntryActionFound = 1,
	VLEntryActionStop = 2,   // 遇到 0x00，目录到此为止
};

typedef NS_ENUM(NSInteger, VLLookupResult) {
	VLLookupError = -1,
	VLLookupNotFound = 0,
	VLLookupFound = 1,
};

/// 解析一个 32 字节目录项：LFN 项与子目录都跳过，命中才填出内容。
static VLEntryAction VLMatchDirectoryEntry(const uint8_t *entry, const uint8_t *wanted11, VLDirEntry *outEntry) {
	if (entry[0] == 0x00) {
		return VLEntryActionStop;
	}
	if (entry[0] == 0xE5) {
		return VLEntryActionContinue;   // 已删除
	}
	uint8_t attributes = entry[11];
	if (attributes == 0x0F) {
		return VLEntryActionContinue;   // 长文件名项
	}
	if ((attributes & 0x10) != 0) {
		return VLEntryActionContinue;   // 子目录
	}
	if (memcmp(entry, wanted11, 11) != 0) {
		return VLEntryActionContinue;
	}
	outEntry->firstCluster = ((uint32_t)VLReadUInt16LE(entry + 20) << 16) | VLReadUInt16LE(entry + 26);
	outEntry->fileLength = VLReadUInt32LE(entry + 28);
	return VLEntryActionFound;
}

/// 把用户给的名字（如 VMLINUZ / VLBOOT.CFG）转成 11 字节的大写空格补齐 8.3 形式。
static void VLDiskBootBuildShortName(NSString *name, uint8_t outBytes[11]) {
	memset(outBytes, ' ', 11);
	const char *utf8 = name.UTF8String;
	if (utf8 == NULL) {
		return;
	}
	const char *dot = strrchr(utf8, '.');
	size_t mainLength = (dot != NULL) ? (size_t)(dot - utf8) : strlen(utf8);
	if (mainLength > 8) {
		mainLength = 8;
	}
	size_t index = 0;
	for (; index < mainLength; index++) {
		outBytes[index] = (uint8_t)toupper((unsigned char)utf8[index]);
	}
	if (dot != NULL) {
		const char *extension = dot + 1;
		size_t extensionLength = strlen(extension);
		if (extensionLength > 3) {
			extensionLength = 3;
		}
		for (index = 0; index < extensionLength; index++) {
			outBytes[8 + index] = (uint8_t)toupper((unsigned char)extension[index]);
		}
	}
}

/// 扫 FAT16 的固定根目录（dataStart 之后 rootEntryCount * 32 字节，不是簇链）。
static VLLookupResult VLScanFixedRoot(NSFileHandle *handle,
									  const VLFATLayout *layout,
									  const uint8_t *wanted11,
									  VLDirEntry *outEntry) {
	uint64_t directorySize = (uint64_t)layout->rootEntryCount * 32;
	uint64_t offset = 0;
	while (offset < directorySize) {
		NSUInteger chunk = (NSUInteger)MIN(directorySize - offset, (uint64_t)VLDiskBootMaxReadLength);
		NSData *data = VLReadAtOffset(handle, layout->rootDirectoryStart + offset, chunk);
		if (data == nil) {
			return VLLookupError;
		}
		const uint8_t *bytes = data.bytes;
		NSUInteger index = 0;
		while (index + 32 <= data.length) {
			VLEntryAction action = VLMatchDirectoryEntry(bytes + index, wanted11, outEntry);
			if (action == VLEntryActionFound) {
				return VLLookupFound;
			}
			if (action == VLEntryActionStop) {
				return VLLookupNotFound;
			}
			index += 32;
		}
		offset += chunk;
	}
	return VLLookupNotFound;
}

/// 扫簇链形式目录（FAT32 根目录、子目录都走这里）。
static VLLookupResult VLScanClusterDirectory(NSFileHandle *handle,
											 const VLFATLayout *layout,
											 uint32_t firstCluster,
											 const uint8_t *wanted11,
											 VLDirEntry *outEntry) {
	uint64_t clusterSize = (uint64_t)layout->sectorsPerCluster * layout->bytesPerSector;
	uint32_t cluster = firstCluster;
	uint32_t visited = 0;
	while (cluster >= 2 && visited < VLDiskBootMaxDirectoryClusters) {
		visited++;
		uint64_t clusterOffset = layout->dataStart + (uint64_t)(cluster - 2) * clusterSize;
		uint64_t read = 0;
		while (read < clusterSize) {
			NSUInteger chunk = (NSUInteger)MIN(clusterSize - read, (uint64_t)VLDiskBootMaxReadLength);
			NSData *data = VLReadAtOffset(handle, clusterOffset + read, chunk);
			if (data == nil) {
				return VLLookupError;
			}
			const uint8_t *bytes = data.bytes;
			NSUInteger index = 0;
			while (index + 32 <= data.length) {
				VLEntryAction action = VLMatchDirectoryEntry(bytes + index, wanted11, outEntry);
				if (action == VLEntryActionFound) {
					return VLLookupFound;
				}
				if (action == VLEntryActionStop) {
					return VLLookupNotFound;
				}
				index += 32;
			}
			read += chunk;
		}
		uint32_t next = 0;
		if (!VLFATNextCluster(handle, layout, cluster, &next)) {
			return VLLookupError;
		}
		if (VLFATClusterIsEnd(layout, next)) {
			break;
		}
		cluster = next;
	}
	return VLLookupNotFound;
}

#pragma mark - 读文件内容

/// 按簇链把文件读出来，连续簇合并成一段读、逐段 append（段长上限 1MB），最后按目录项长度截断。
static NSData *VLFATReadClusterChain(NSFileHandle *handle,
									 const VLFATLayout *layout,
									 uint32_t firstCluster,
									 uint32_t fileLength,
									 NSError **error) {
	if (fileLength == 0) {
		return [NSData data];
	}
	if (firstCluster < 2) {
		if (error != NULL) {
			*error = VLDiskBootError(10, @"启动文件的起始簇非法");
		}
		return nil;
	}

	uint64_t clusterSize = (uint64_t)layout->sectorsPerCluster * layout->bytesPerSector;
	// 目录项里的长度决定了这条链最多有多少簇，同时天然成了防死循环的上限。
	NSUInteger needed = (NSUInteger)(((uint64_t)fileLength + clusterSize - 1) / clusterSize);
	uint32_t *clusters = malloc(needed * sizeof(uint32_t));
	if (clusters == NULL) {
		if (error != NULL) {
			*error = VLDiskBootError(11, @"内存不足，无法读取启动文件");
		}
		return nil;
	}

	NSUInteger count = 0;
	uint32_t cluster = firstCluster;
	while (count < needed) {
		clusters[count++] = cluster;
		uint32_t next = 0;
		if (!VLFATNextCluster(handle, layout, cluster, &next)) {
			free(clusters);
			if (error != NULL) {
				*error = VLDiskBootError(12, @"读取 FAT 表失败");
			}
			return nil;
		}
		if (VLFATClusterIsEnd(layout, next)) {
			break;
		}
		cluster = next;
	}

	NSMutableData *result = [NSMutableData dataWithCapacity:fileLength];
	uint64_t remaining = fileLength;
	NSUInteger index = 0;
	while (index < count && remaining > 0) {
		uint32_t runStart = clusters[index];
		NSUInteger runLength = 1;
		index++;
		// 把物理连续的簇并成一段，少读几次盘。
		while (index < count && clusters[index] == runStart + (uint32_t)runLength) {
			runLength++;
			index++;
		}
		uint64_t runOffset = layout->dataStart + (uint64_t)(runStart - 2) * clusterSize;
		uint64_t toRead = MIN((uint64_t)runLength * clusterSize, remaining);
		uint64_t read = 0;
		while (read < toRead) {
			NSUInteger chunk = (NSUInteger)MIN(toRead - read, (uint64_t)VLDiskBootMaxReadLength);
			NSData *data = VLReadAtOffset(handle, runOffset + read, chunk);
			if (data == nil) {
				free(clusters);
				if (error != NULL) {
					*error = VLDiskBootError(13, @"读取启动文件内容时越界或短读");
				}
				return nil;
			}
			[result appendData:data];
			read += chunk;
		}
		remaining -= toRead;
	}
	free(clusters);
	return result;
}

#pragma mark - GPT 分区扫描

/// 逐个扫 GPT 分区项，对每个非空分区试解析 FAT；第一个解析成功的就用它。
static BOOL VLDiskBootFindFATPartition(NSFileHandle *handle,
									   VLFATLayout *outLayout,
									   uint64_t *outPartitionStart,
									   uint64_t *outPartitionSize) {
	// LBA0 的保护性 MBR 只作预检，缺签名也继续按 GPT 试，不拿它当失败依据。
	NSData *mbr = VLReadAtOffset(handle, 0, VLDiskBootSectorSize);
	if (mbr == nil) {
		return NO;
	}
	const uint8_t *mbrBytes = mbr.bytes;
	if (mbrBytes[510] != 0x55 || mbrBytes[511] != 0xAA) {
		[VLStartupLog log:@"系统盘缺少 MBR 签名，仍按 GPT 继续解析"];
	}

	NSData *headerData = VLReadAtOffset(handle, VLDiskBootSectorSize, VLDiskBootSectorSize);
	if (headerData == nil) {
		return NO;
	}
	const uint8_t *header = headerData.bytes;
	if (memcmp(header, "EFI PART", 8) != 0) {
		return NO;
	}

	uint64_t entriesLBA = VLReadUInt64LE(header + 72);
	uint32_t numberOfPartitionEntries = VLReadUInt32LE(header + 80);
	uint32_t sizeOfPartitionEntry = VLReadUInt32LE(header + 84);
	// 分区项里要到偏移 40 的 lastLBA，不足 48 字节的项直接不认。
	if (entriesLBA == 0 || numberOfPartitionEntries == 0 || sizeOfPartitionEntry < 48) {
		return NO;
	}

	uint64_t entriesStart = entriesLBA * VLDiskBootSectorSize;
	uint32_t entryCount = MIN(numberOfPartitionEntries, VLDiskBootMaxPartitions);
	for (uint32_t i = 0; i < entryCount; i++) {
		uint64_t entryOffset = entriesStart + (uint64_t)i * sizeOfPartitionEntry;
		NSData *entryData = VLReadAtOffset(handle, entryOffset, 48);
		if (entryData == nil) {
			break;   // 越界（盘比声明的小），后面的项也不用看了
		}
		const uint8_t *entry = entryData.bytes;

		BOOL isEmpty = YES;
		for (NSUInteger j = 0; j < 16; j++) {
			if (entry[j] != 0) {
				isEmpty = NO;
				break;
			}
		}
		if (isEmpty) {
			continue;
		}

		uint64_t firstLBA = VLReadUInt64LE(entry + 32);
		uint64_t lastLBA = VLReadUInt64LE(entry + 40);
		if (firstLBA == 0 || lastLBA < firstLBA) {
			continue;
		}

		uint64_t partitionStart = firstLBA * VLDiskBootSectorSize;
		if (VLFATParseLayout(handle, partitionStart, outLayout)) {
			*outPartitionStart = partitionStart;
			*outPartitionSize = (lastLBA - firstLBA + 1) * VLDiskBootSectorSize;
			return YES;
		}
	}
	return NO;
}

#pragma mark - 主体

@interface VLDiskBootVolume ()
@property (nonatomic, readwrite, copy) NSString *commandLine;
@end

@implementation VLDiskBootVolume {
	NSString *_imagePath;
	NSFileHandle *_handle;
	VLFATLayout _layout;
	BOOL _hasLayout;
}

+ (instancetype)volumeWithDiskImagePath:(NSString *)imagePath {
	VLDiskBootVolume *volume = [[VLDiskBootVolume alloc] init];
	volume->_imagePath = [imagePath copy];
	return volume;
}

- (void)dealloc {
	[self close];
}

- (BOOL)openWithError:(NSError **)error {
	[self close];
	self.commandLine = nil;

	NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:_imagePath];
	if (handle == nil) {
		if (error != NULL) {
			*error = VLDiskBootError(1, @"打不开系统盘镜像文件");
		}
		return NO;
	}
	_handle = handle;

	// 找分区 → 解析 FAT → 读 VLBOOT.CFG，任何一步失败都说明这盘还没装好或装法不对。
	VLFATLayout layout;
	uint64_t partitionStart = 0;
	uint64_t partitionSize = 0;
	if (!VLDiskBootFindFATPartition(handle, &layout, &partitionStart, &partitionSize)) {
		[VLStartupLog log:@"系统盘里没找到可用的启动分区（GPT + FAT16/32）"];
		[self close];
		if (error != NULL) {
			*error = VLDiskBootError(2, @"系统盘里找不到启动分区，可能系统还没安装完成");
		}
		return NO;
	}

	_layout = layout;
	_hasLayout = YES;
	[VLStartupLog log:@"磁盘启动分区：偏移 0x%llx 共 %llu 字节",
		(unsigned long long)partitionStart, (unsigned long long)partitionSize];

	NSData *configData = [self dataForFileNamed:@"VLBOOT.CFG" error:NULL];
	NSString *commandLine = configData.length > 0
		? [[NSString alloc] initWithData:configData encoding:NSUTF8StringEncoding]
		: nil;
	commandLine = [commandLine stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	if (commandLine.length == 0) {
		[VLStartupLog log:@"启动分区里没有有效的 VLBOOT.CFG，视为系统盘未装好"];
		[self close];
		self.commandLine = nil;
		if (error != NULL) {
			*error = VLDiskBootError(3, @"启动分区里没有有效的 VLBOOT.CFG，系统盘可能还没安装完成");
		}
		return NO;
	}

	self.commandLine = commandLine;
	[VLStartupLog log:@"已从系统盘读到内核命令行"];
	return YES;
}

- (NSData *)dataForFileNamed:(NSString *)name error:(NSError **)error {
	if (_handle == nil || !_hasLayout) {
		if (error != NULL) {
			*error = VLDiskBootError(4, @"系统盘还没打开或没找到启动分区");
		}
		return nil;
	}
	if (name.length == 0) {
		if (error != NULL) {
			*error = VLDiskBootError(5, @"文件名不能为空");
		}
		return nil;
	}

	uint8_t wanted11[11];
	VLDiskBootBuildShortName(name, wanted11);

	VLDirEntry entry = {0, 0};
	VLLookupResult result = _layout.isFAT32
		? VLScanClusterDirectory(_handle, &_layout, _layout.rootCluster, wanted11, &entry)
		: VLScanFixedRoot(_handle, &_layout, wanted11, &entry);
	if (result == VLLookupError) {
		if (error != NULL) {
			*error = VLDiskBootError(6, @"读启动分区目录失败");
		}
		return nil;
	}
	if (result == VLLookupNotFound) {
		if (error != NULL) {
			*error = VLDiskBootError(7, [NSString stringWithFormat:@"启动分区里找不到文件 %@", name]);
		}
		return nil;
	}

	return VLFATReadClusterChain(_handle, &_layout, entry.firstCluster, entry.fileLength, error);
}

- (void)close {
	if (_handle != nil) {
		[_handle closeFile];
		_handle = nil;
	}
	_hasLayout = NO;
}

@end
