TARGET := iphone:clang:latest:16.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = SpringBoard Camera

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VCAM
THEOS_PACKAGE_SCHEME = roothide
VCAM_FILES = Tweak.x
VCAM_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-deprecated-declarations -Wno-error

SUBPROJECTS += Preferences

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "sbreload || killall -9 SpringBoard"