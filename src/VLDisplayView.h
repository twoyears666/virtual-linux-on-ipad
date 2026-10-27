#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, VLDisplayTouchPhase) {
	VLDisplayTouchPhaseBegan = 0,
	VLDisplayTouchPhaseMoved,
	VLDisplayTouchPhaseEnded,
};

/// 客户机画面显示区：等比铺满、黑底、圆角，没画面时显示状态文字。
@interface VLDisplayView : UIView

/// 没有画面时显示的文字（例如"正在启动内核…"）。
@property (nonatomic, copy) NSString *statusText;

/// 手指落在画面上时回调，x/y 是画面区域内归一化后的比例（0 – 1，左上角原点）。
/// 落在黑边上不会触发。
@property (nonatomic, copy) void (^touchHandler)(VLDisplayTouchPhase phase, CGFloat x, CGFloat y);

@property (nonatomic, readonly) BOOL hasFrame;

/// 帧数据是 BGRA 8888、行距紧密。必须在主线程调用。
- (void)updateWithWidth:(uint32_t)width height:(uint32_t)height frame:(NSData *)frame;

/// 回到无画面状态。
- (void)clearFrame;

@end
