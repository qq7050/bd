# Theos Makefile — BaiduNetdiskTools (All-in-One)
# 目标: iOS 15.0+ arm64 (与 13.35.5 的 MinimumOSVersion=15.0 一致)

TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = netdisk_iPhone
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BaiduNetdiskTools
BaiduNetdiskTools_FILES = Tweak.xm
BaiduNetdiskTools_CFLAGS = -fobjc-arc -Wno-unused-parameter
BaiduNetdiskTools_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/tweak.mk

# 编译: make package
# 产物: packages/com.xxx.baiduspeedboost_1.0-1+deb11u1_iphoneos-arm.deb
# 提取 deb 里的 Library/MobileSubstrate/DynamicLibraries/BaiduSpeedBoost.dylib
# 用 TrollFools 注入到百度网盘 IPA（与现有 baidudisk.dylib 可共存）
