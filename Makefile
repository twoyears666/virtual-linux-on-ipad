export ARCHS = arm64
export TARGET = iphone:clang:latest:14.0
export THEOS_PACKAGE_SCHEME = rootless
export PACKAGE_VERSION = 0.1.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = VirtualLinux

VirtualLinux_FILES = $(wildcard src/*.m)
VirtualLinux_FRAMEWORKS = UIKit Foundation UniformTypeIdentifiers
VirtualLinux_CFLAGS = -fobjc-arc -Wall
VirtualLinux_CODESIGN_FLAGS = -Sentitlements.plist
VirtualLinux_INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/application.mk

# === 私有 Hypervisor 运行时 —— Apple 二进制不入库，本地抽出来才打进去 ===
# 用 tools/extract-hypervisor.py 生成 build-private/Frameworks/Hypervisor.framework；
# 目录不存在（例如 CI 上）就跳过，产物里不会出现 Apple 私有二进制。
before-package::
	@if [ -d build-private/Frameworks/Hypervisor.framework ]; then \
		app="$(THEOS_STAGING_DIR)/Applications/VirtualLinux.app"; \
		mkdir -p "$$app/Frameworks"; \
		cp -R build-private/Frameworks/Hypervisor.framework "$$app/Frameworks/"; \
		echo "已打入 Hypervisor.framework"; \
	fi
