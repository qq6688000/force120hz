TARGET := iphone:clang:16.5:14.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Force120Hz

Force120Hz_FILES = Tweak.x
Force120Hz_FRAMEWORKS = UIKit QuartzCore
Force120Hz_CFLAGS = -fobjc-arc -Wno-unguarded-availability-new -Wno-deprecated-declarations -Wno-format -Wno-unused-variable -Wno-unused-function
# Linux/iSH 本地验证编译用 lld；macOS CI 用 Apple 自带 ld
ifeq ($(shell uname -s),Darwin)
else
Force120Hz_LDFLAGS = -fuse-ld=lld
endif

include $(THEOS_MAKE_PATH)/tweak.mk
