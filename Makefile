THEOS_PACKAGE_SCHEME ?= roothide
ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
include $(THEOS)/makefiles/common.mk
TWEAK_NAME = DomainProxy
DomainProxy_FILES = Tweak.xm
DomainProxy_CFLAGS = -fobjc-arc
DomainProxy_FRAMEWORKS = Foundation CFNetwork
include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += settingsapp
include $(THEOS_MAKE_PATH)/aggregate.mk

after-stage::
	chmod 755 $(THEOS_STAGING_DIR)/DEBIAN/postinst $(THEOS_STAGING_DIR)/DEBIAN/postrm
