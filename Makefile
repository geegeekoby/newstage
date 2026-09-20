export THEOS_PACKAGE_SCHEME = rootless
export TARGET = iphone:clang:16.5:14.0

# arm64 only on purpose. The Linux Theos toolchain emits arm64e slices with the
# pre-iOS-14 ptrauth ABI (subtype 0x2 instead of 0x80000002), which dyld refuses
# to load; an arm64 slice loads into arm64e processes such as SpringBoard just
# fine. Build on macOS with ARCHS="arm64 arm64e" if a native slice is wanted.
export ARCHS = arm64

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += springboard
SUBPROJECTS += app
SUBPROJECTS += prefs

include $(THEOS_MAKE_PATH)/aggregate.mk
