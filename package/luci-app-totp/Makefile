# luci-app-totp -- OpenWrt LuCI TOTP 二次验证插件（实验版）
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-totp
PKG_VERSION:=0.1.0-r6
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=experimental

LUCI_TITLE:=LuCI TOTP 二次验证（实验版）
LUCI_DEPENDS:=+luci-base +luci-compat
# SSH 同步为可选项，不在 DEPENDS 里强制，避免无 SSH 需求的用户被装上 OpenSSH：
#   opkg install openssh-server-pam google-authenticator-libpam
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt-Luci
$(eval $(call BuildPackage,$(PKG_NAME)))
