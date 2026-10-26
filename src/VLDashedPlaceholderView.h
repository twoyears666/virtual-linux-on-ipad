#import <UIKit/UIKit.h>

/// 虚线占位框，用来标记「这里应该放一张图」。
/// 目前用于虚拟机截图位置：运行后替换成客户机画面。
@interface VLDashedPlaceholderView : UIView

@property (nonatomic, copy) NSString *text;

@end
