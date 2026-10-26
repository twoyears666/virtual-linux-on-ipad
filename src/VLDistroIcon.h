#import <UIKit/UIKit.h>

/// 发行版图标映射：用 SF Symbols 表现常见发行版，不内置真实 logo 资源。
@interface VLDistroIcon : NSObject

/// 可选发行版标识列表（alpine / debian / ubuntu / arch / fedora / linux）。
+ (NSArray<NSString *> *)allIdentifiers;

+ (NSString *)displayNameForIdentifier:(NSString *)identifier;
+ (NSString *)symbolNameForIdentifier:(NSString *)identifier;
+ (UIColor *)colorForIdentifier:(NSString *)identifier;

/// 官方 PNG 图标（Resources/logos/<id>.png）；缺失时退回 SF Symbol。
+ (UIImage *)imageForIdentifier:(NSString *)identifier;

/// 按正方形等比缩放到指定尺寸，供列表与按钮使用。
+ (UIImage *)thumbnailForIdentifier:(NSString *)identifier size:(CGFloat)size;

@end
