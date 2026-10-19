THEOS_PACKAGE_SCHEME ?= roothide
ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
include $(THEOS)/makefiles/common.mk
TWEAK_NAME = DomainProxy
DomainProxy_FILES = Tweak.xm
DomainProxy_CFLAGS = -fobjc-arc
DomainProxy_FRAMEWORKS = Foundation CFNetwork
include $(THEOS_MAKE_PATH)/tweak.mk
