#import <Foundation/Foundation.h>

/// 统一日志：所有运行期信息追加到 <虚拟机目录>/logs/app.log，超过大小自动滚动一份。
/// 设置页可把「系统信息 + 启动日志 + 统一日志 + 崩溃记录」合并导出一份文本分享出去。
@interface VLLog : NSObject

/// 准备日志目录；应在启动最早阶段调用一次。
+ (void)start;

+ (void)log:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);

/// 已格式化好的整行（VLStartupLog 复用它，避免二次格式化）。
+ (void)writeLine:(NSString *)line;

/// 日志目录绝对路径（/var/mobile/Media/VirtualMachines/logs，沙盒不可写时退回 Documents/logs）。
+ (NSString *)logsDirectoryPath;

/// 上述目录里的 app.log 绝对路径。
+ (NSString *)logFilePath;

/// 合并导出为临时文本文件，返回可分享的 URL；失败返回 nil。
+ (NSURL *)exportReportURL;

@end
