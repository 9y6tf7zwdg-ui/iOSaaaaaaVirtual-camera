BUNDLE_NAME = VCAMPrefs
VCAMPrefs_FILES = VCAMRootListController.m
VCAMPrefs_FRAMEWORKS = UIKit
VCAMPrefs_LDFLAGS = -undefined dynamic_lookup
VCAMPrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/bundle.mk

after-install::
	install.exec "sbreload || killall -9 SpringBoard"