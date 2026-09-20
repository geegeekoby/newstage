export THEOS_PACKAGE_SCHEME = rootless
export TARGET = iphone:clang:16.5:14.0

# Both slices are needed: the processes hooked on an A12 or newer device are
# arm64e (SpringBoard, Settings), while App Store apps the per-app dylib goes
# into are arm64. PreferenceLoader in particular will not load an arm64 bundle on
# an arm64e device, so an arm64e slice is not optional.
#
# The Linux toolchain compiles arm64e with the pre-iOS-14 ptrauth ABI, which iOS
# 14.5 and later refuse to load, and it emits a warning about it while linking
# that can be ignored: tools/newabi.py patches the staged binaries to the new ABI
# and re-signs them before the package is built.
export ARCHS = arm64 arm64e

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += springboard
SUBPROJECTS += app
SUBPROJECTS += prefs

include $(THEOS_MAKE_PATH)/aggregate.mk

# Runs once the three subprojects have staged and before the .deb is assembled,
# which is the only point where the finished fat binaries exist.
after-stage::
	@python3 $(THEOS_PROJECT_DIR)/tools/newabi.py "$(THEOS_STAGING_DIR)"
