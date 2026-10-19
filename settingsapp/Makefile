ARCHS = arm64
TARGET = iphone:clang:latest:15.0
include $(THEOS)/makefiles/common.mk
APPLICATION_NAME = DomainProxyApp
DomainProxyApp_FILES = main.mm
DomainProxyApp_FRAMEWORKS = UIKit Foundation
DomainProxyApp_CFLAGS = -fobjc-arc
DomainProxyApp_CODESIGN_FLAGS = -Sentitlements.plist
DomainProxyApp_RESOURCE_FILES = ../layout/Library/DomainProxy/proxy.pac
include $(THEOS_MAKE_PATH)/application.mk
