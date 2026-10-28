#import <Foundation/Foundation.h>

// 启动/崩溃日志工具：把阶段埋点追加到 <虚拟机目录>/logs/startup.log，
// 把未捕获异常与致命信号写入 <虚拟机目录>/logs/crash.txt。
// 供盲修闪退时取回日志定位问题；UIFileSharingEnabled 已开启，可经文件 App 取回。
@interface VLStartupLog : NSObject

+ (void)installExceptionHandlers;
+ (void)log:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);

@end