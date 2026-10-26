#import "VLDiskImage.h"

@implementation VLDiskImage

+ (instancetype)diskWithName:(NSString *)name sizeGB:(NSUInteger)sizeGB {
	VLDiskImage *disk = [[VLDiskImage alloc] init];
	disk.identifier = NSUUID.UUID.UUIDString;
	disk.name = name;
	disk.sizeGB = sizeGB;
	disk.readOnly = NO;
	disk.path = @"";
	return disk;
}

@end
