ARCHS = arm64
TARGET := iphone:clang:latest:14.0

THEOS_PACKAGE_SCHEME = roothide

INSTALL_TARGET_PROCESSES = SpringBoard mediaserverd

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VCam VCamMediaServer

VCam_FILES = Tweak.xm MediaManager.m VCamSharedState.m
VCam_CFLAGS = -fobjc-arc
VCam_CXXFLAGS = -fobjc-arc -std=c++17
VCam_LDFLAGS = -std=c++17
VCam_FRAMEWORKS = UIKit AVFoundation CoreMedia CoreVideo CoreImage ImageIO QuartzCore
VCam_PRIVATE_FRAMEWORKS =

VCamMediaServer_FILES = MediaServer.x VCamMediaServerSource.m
VCamMediaServer_CFLAGS = -fobjc-arc
VCamMediaServer_FRAMEWORKS = Foundation AVFoundation CoreMedia CoreVideo CoreImage ImageIO
VCamMediaServer_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
