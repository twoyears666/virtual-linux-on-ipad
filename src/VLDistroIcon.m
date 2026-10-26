#import "VLDistroIcon.h"

@implementation VLDistroIcon

+ (NSArray<NSString *> *)allIdentifiers {
	return @[ @"alpine", @"debian", @"ubuntu", @"arch", @"fedora", @"linux" ];
}

+ (NSString *)displayNameForIdentifier:(NSString *)identifier {
	if ([identifier isEqualToString:@"alpine"]) {
		return @"Alpine";
	}
	if ([identifier isEqualToString:@"debian"]) {
		return @"Debian";
	}
	if ([identifier isEqualToString:@"ubuntu"]) {
		return @"Ubuntu";
	}
	if ([identifier isEqualToString:@"arch"]) {
		return @"Arch";
	}
	if ([identifier isEqualToString:@"fedora"]) {
		return @"Fedora";
	}
	return @"Linux";
}

+ (NSString *)symbolNameForIdentifier:(NSString *)identifier {
	if ([identifier isEqualToString:@"alpine"]) {
		return @"snowflake";
	}
	if ([identifier isEqualToString:@"debian"]) {
		return @"shippingbox";
	}
	if ([identifier isEqualToString:@"ubuntu"]) {
		return @"circle.hexagongrid";
	}
	if ([identifier isEqualToString:@"arch"]) {
		return @"triangle";
	}
	if ([identifier isEqualToString:@"fedora"]) {
		return @"flame";
	}
	return @"terminal";
}

+ (UIColor *)colorForIdentifier:(NSString *)identifier {
	if ([identifier isEqualToString:@"alpine"]) {
		return [UIColor colorWithRed:0.06 green:0.43 blue:0.75 alpha:1.0];
	}
	if ([identifier isEqualToString:@"debian"]) {
		return [UIColor colorWithRed:0.84 green:0.04 blue:0.33 alpha:1.0];
	}
	if ([identifier isEqualToString:@"ubuntu"]) {
		return [UIColor colorWithRed:0.91 green:0.33 blue:0.13 alpha:1.0];
	}
	if ([identifier isEqualToString:@"arch"]) {
		return [UIColor colorWithRed:0.09 green:0.58 blue:0.82 alpha:1.0];
	}
	if ([identifier isEqualToString:@"fedora"]) {
		return [UIColor colorWithRed:0.16 green:0.25 blue:0.45 alpha:1.0];
	}
	return [UIColor grayColor];
}

+ (UIImage *)imageForIdentifier:(NSString *)identifier {
	NSString *resolved = identifier.length > 0 ? identifier : @"linux";
	UIImage *image = [UIImage imageNamed:[NSString stringWithFormat:@"logos/%@.png", resolved]];
	if (image == nil) {
		image = [UIImage imageNamed:[NSString stringWithFormat:@"%@.png", resolved]];
	}
	if (image == nil) {
		image = [UIImage systemImageNamed:[self symbolNameForIdentifier:resolved]];
	}
	return image;
}

+ (UIImage *)thumbnailForIdentifier:(NSString *)identifier size:(CGFloat)size {
	return [self thumbnailForImage:[self imageForIdentifier:identifier] size:size];
}

+ (UIImage *)templateThumbnailForIdentifier:(NSString *)identifier size:(CGFloat)size {
	UIImage *thumbnail = [self thumbnailForIdentifier:identifier size:size];
	if (thumbnail == nil) {
		return nil;
	}
	return [thumbnail imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

+ (UIImage *)thumbnailForImage:(UIImage *)image size:(CGFloat)size {
	if (image == nil || size <= 0.0) {
		return image;
	}

	CGFloat width = image.size.width;
	CGFloat height = image.size.height;
	if (width <= 0.0 || height <= 0.0) {
		return image;
	}

	CGFloat scale = MIN(size / width, size / height);
	CGRect target = CGRectMake((size - width * scale) / 2.0,
							   (size - height * scale) / 2.0,
							   width * scale,
							   height * scale);

	UIGraphicsImageRenderer *renderer =
		[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(size, size)];
	return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
		[image drawInRect:target];
	}];
}

@end
