include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = DynamicStagePrefs

DynamicStagePrefs_FILES = $(wildcard *.m)
DynamicStagePrefs_INSTALL_PATH = /Library/PreferenceBundles
DynamicStagePrefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -I../shared
DynamicStagePrefs_FRAMEWORKS = UIKit CoreGraphics QuartzCore AVFoundation
DynamicStagePrefs_PRIVATE_FRAMEWORKS = Preferences
DynamicStagePrefs_LDFLAGS = -Wl,-segalign,4000

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences"$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/DynamicStagePrefs.plist"$(ECHO_END)
