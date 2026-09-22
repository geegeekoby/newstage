include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DynamicStageApp

DynamicStageApp_FILES = $(wildcard *.xm) $(wildcard *.m) ../shared/DSPreferences.m ../shared/DSExclusions.m ../shared/DSDiagnostics.m ../shared/DSBootstrap.m
DynamicStageApp_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -I../shared
DynamicStageApp_FRAMEWORKS = Foundation
DynamicStageApp_WEAK_FRAMEWORKS = UIKit CoreGraphics QuartzCore
DynamicStageApp_LDFLAGS = -Wl,-segalign,4000
# MobileSubstrate's generator links CydiaSubstrate by rpath. A sandboxed app
# cannot resolve that, so dyld refuses the image and the constructor never
# runs. The internal generator hooks with the Objective-C runtime directly.
DynamicStageApp_LOGOS_DEFAULT_GENERATOR = internal

include $(THEOS_MAKE_PATH)/tweak.mk
