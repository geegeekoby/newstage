include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DynamicStageApp

DynamicStageApp_FILES = $(wildcard *.xm) $(wildcard *.m) ../shared/DSPreferences.m
DynamicStageApp_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -I../shared
DynamicStageApp_FRAMEWORKS = UIKit CoreGraphics QuartzCore
DynamicStageApp_LDFLAGS = -Wl,-segalign,4000

include $(THEOS_MAKE_PATH)/tweak.mk
