ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = smoba

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = cheat

cheat_FILES = Tweak.xm imgui/imgui.cpp imgui/imgui_draw.cpp imgui/imgui_tables.cpp \
              imgui/imgui_widgets.cpp imgui/backends/imgui_impl_metal.mm \
              imgui/backends/imgui_impl_ios.mm
cheat_CFLAGS = -fobjc-arc -Iimgui -Iimgui/backends -w
cheat_CCFLAGS = -std=c++17 -fno-exceptions -fno-rtti -Iimgui -w
cheat_LDFLAGS = -framework UIKit -framework Metal -framework MetalKit -framework QuartzCore
cheat_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 smoba || true"
