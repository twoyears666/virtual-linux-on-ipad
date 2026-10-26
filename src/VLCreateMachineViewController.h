#import <UIKit/UIKit.h>

@class VLVMConfiguration;

/// 新建虚拟机弹窗：确定名称、CPU 核心数、内存与磁盘容量，创建后交给调用方入列。
@interface VLCreateMachineViewController : UIViewController

/// 点「创建」后回调组装好的配置。
@property (nonatomic, copy) void (^completion)(VLVMConfiguration *configuration);

- (instancetype)initWithSuggestedName:(NSString *)suggestedName;

@end