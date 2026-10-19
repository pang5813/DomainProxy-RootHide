ARCHS = arm64
TARGET = iphone:clang:latest:16.0
include $(THEOS)/makefiles/common.mk
APPLICATION_NAME = DomainProxyApp
DomainProxyApp_FILES = main.mm
DomainProxyApp_FRAMEWORKS = UIKit Foundation
DomainProxyApp_CFLAGS = -fobjc-arc
DomainProxyApp_CODESIGN_FLAGS = -Sentitlements.plist
include $(THEOS_MAKE_PATH)/application.mk
