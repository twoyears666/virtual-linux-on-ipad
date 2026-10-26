#import <UIKit/UIKit.h>

/// 虚线占位框，用来标记「这里应该放一张图」。
/// 目前用于虚拟机截图位置：运行后替换成客户机画面。
@interface VLDashedPlaceholderView : UIView

@property (nonatomic, copy) NSString *text;

/// 点按整个占位区的回调（当前用于直接启动虚拟机）。
@property (nonatomic, copy) void (^onTap)(void);

@end
