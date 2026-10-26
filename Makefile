export ARCHS = arm64
export TARGET = iphone:clang:latest:14.0
export THEOS_PACKAGE_SCHEME = rootless
export PACKAGE_VERSION = 0.1.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = VirtualLinux

VirtualLinux_FILES = $(wildcard src/*.m)
VirtualLinux_FRAMEWORKS = UIKit Foundation
VirtualLinux_CFLAGS = -fobjc-arc -Wall
VirtualLinux_CODESIGN_FLAGS = -Sentitlements.plist
VirtualLinux_INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/application.mk
