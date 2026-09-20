include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DynamicStage

DynamicStage_FILES = $(wildcard *.xm) $(wildcard *.m) ../shared/DSPreferences.m ../shared/DSExclusions.m ../shared/DSDiagnostics.m
DynamicStage_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -I../shared
DynamicStage_FRAMEWORKS = UIKit CoreGraphics QuartzCore AudioToolbox
DynamicStage_PRIVATE_FRAMEWORKS = FrontBoard FrontBoardServices BaseBoard SpringBoardServices
DynamicStage_LDFLAGS = -Wl,-segalign,4000

include $(THEOS_MAKE_PATH)/tweak.mk
