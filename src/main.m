#import <UIKit/UIKit.h>

#import "VLAppDelegate.h"
#import "VLLog.h"
#import "VLStartupLog.h"

int main(int argc, char *argv[]) {
	@autoreleasepool {
		[VLLog start];
		[VLStartupLog installExceptionHandlers];
		[VLStartupLog log:@"进入 UIApplicationMain"];

		int status = UIApplicationMain(argc, argv, nil, NSStringFromClass([VLAppDelegate class]));

		[VLStartupLog log:@"UIApplicationMain 意外返回 %d", status];
		return status;
	}
}