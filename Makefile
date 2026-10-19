THEOS_PACKAGE_SCHEME ?= roothide
ARCHS = arm64
TARGET = iphone:clang:latest:16.0
include $(THEOS)/makefiles/common.mk
SUBPROJECTS = settingsapp controller
include $(THEOS_MAKE_PATH)/aggregate.mk

after-stage::
	chmod 4755 $(THEOS_STAGING_DIR)/usr/bin/domainproxyctl
	chmod 755 $(THEOS_STAGING_DIR)/usr/libexec/domainproxy-core
