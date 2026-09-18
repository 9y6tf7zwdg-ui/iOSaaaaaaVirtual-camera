TARGET := iphone:clang:latest:11.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = SpringBoard Camera
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VCAM
VCAM_FILES = Tweak.x Preferences.x
VCAM_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-deprecated-declarations -Wno-error

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "sbreload || killall -9 SpringBoard"