ARCHS = arm64
TARGET = iphone:clang:latest:16.0
include $(THEOS)/makefiles/common.mk
TOOL_NAME = domainproxyctl
domainproxyctl_FILES = main.mm
domainproxyctl_CFLAGS = -fobjc-arc
domainproxyctl_FRAMEWORKS = Foundation
domainproxyctl_INSTALL_PATH = /usr/bin
domainproxyctl_CODESIGN_FLAGS = -S../settingsapp/entitlements.plist
include $(THEOS_MAKE_PATH)/tool.mk
