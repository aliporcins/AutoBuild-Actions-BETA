#!/bin/bash
# AutoBuild Module by Hyy2001 <https://github.com/Hyy2001X/AutoBuild-Actions-BETA>
# AutoBuild DiyScript -- adapted for aliporcins/AutoBuild-Actions-BETA:
# builds official openwrt-25.12 for x86_64 with the production VM100 package set.
# No credentials are baked into the image; default address is 192.168.2.1
# (user decision 2026-11-20, main-router rebuild: the production LAN
# address is now baked in so a fresh flash comes up at 192.168.2.1).

Firmware_Diy_Core() {

	Author=AUTO
	# 作者名称, AUTO: [自动识别]

	Author_URL=AUTO
	# 自定义作者网站或域名, AUTO: [自动识别]

	Default_Flag=AUTO
	# 固件标签 (名称后缀), 适用不同配置文件, AUTO: [自动识别]

	Default_IP="192.168.2.1"
	# 固件 IP 地址 (user decision 2026-11-20: production 192.168.2.1 is
	# now baked in; both x86_64 and AX6000 builds use it as the default.
	# A workflow Tempoary_IP input still overrides this when supplied.)

	Default_Title="Powered by AutoBuild-Actions"
	# 固件终端首页显示的额外信息

	Short_Fw_Date=true
	# 简短的固件日期, true: [20210601]; false: [202106012359]

	x86_Full_Images=false
	# 额外上传已检测到的 x86 虚拟磁盘镜像, true: [上传]; false: [不上传]
	# (Both squashfs combined images -- plain + efi -- are shipped via the
	#  patched Process_Fw_Core in AutoBuild_Function.sh regardless of this flag.)

	Fw_MFormat=AUTO
	# 自定义固件格式, AUTO: [自动识别]

	Regex_Skip="packages|buildinfo|sha256sums|manifest|kernel|rootfs|factory|itb|profile|ext4|json"
	# 输出固件时丢弃包含该内容的固件/文件 (ext4 stays out of the Release dir;
	# it remains available in the bin artifact)

	# AX6000 (qualcommax/ipq50xx) only: the xmir-patcher flash flow needs
	# the initramfs-factory.ubi as the temporary firmware, so "factory"
	# must NOT be skipped for this target, and both .bin (sysupgrade)
	# and .ubi (factory) outputs must be collected. Detect via the target
	# line in .config (already copied + defconfig'd by the workflow
	# before this runs). Other targets keep the defaults above.
	if grep -q "^CONFIG_TARGET_qualcommax=y" .config 2>/dev/null; then
		Regex_Skip="packages|buildinfo|sha256sums|manifest|kernel|rootfs|itb|profile|ext4|json"
		Fw_MFormat="bin ubi"
	fi

	AutoBuild_Features=false
	# 添加 AutoBuild 固件特性, true: [开启]; false: [关闭]
	# (false: no autoupdate app, no banner/profile overrides -- image stays
	#  aligned with the production package set)

	AutoBuild_Features_Patch=false
	AutoBuild_Features_Kconfig=false
}

Firmware_Diy() {

	# External packages, ALL pinned to exact commits (core3 lesson: never float
	# on a moving branch). Runs after feeds install, before make defconfig.
	# luci-app-totp (vendored in this repo, user's own ucode package).
	# Restored on x86_64 2026-11-20 and on AX6000 2026-11-21 (user
	# decisions). It needs no clone here -- BUT it does need copying
	# into the tree: the repo's package/ dir is not the openwrt
	# tree's package/ dir, and nothing else copies it, so make
	# defconfig silently dropped CONFIG_PACKAGE_luci-app-totp and
	# every build so far shipped without TOTP (found 2026-11-18).
	# Gated on the package being selected, not on the target.
	if grep -q "^CONFIG_PACKAGE_luci-app-totp=y" .config 2>/dev/null; then
	cp -a $GITHUB_WORKSPACE/package/luci-app-totp package/luci-app-totp
	[ -d package/luci-app-totp ] || { echo "ERROR: vendored luci-app-totp missing from tree"; exit 1; }
	fi

	# 2026-11-21: AX6000 dropped daed (user decision); only clone/build
	# it when the config selects it. x86_64 and xiaomi_ax6000 (25.12)
	# still select daed and are unaffected.
	if grep -q "^CONFIG_PACKAGE_daed=y" .config 2>/dev/null; then
		# Defensive: official 25.12 feeds ship no daed, but drop any feed copy
		# if one ever appears, so the pinned kenzok8 copy is the only one.
		rm -rf feeds/packages/net/daed feeds/luci/applications/luci-app-daed
	
		# daed (dae + wing) + luci-app-daede UI -- kenzok8, pinned 2026-11-19 (daed 2026.11.18)
		# (switched from QiuSimons after runs 2-5 died in its Build/Prepare:
		# ';'-chained pnpm web build, then missing system Go for go get).
		# kenzok8's daed/Makefile Prepare only unpacks a CI prebuilt tarball
		# (PKG_VERSION 2026.11.18, PKG_HASH ae3f66c6...), no go get / pnpm.
		git clone https://github.com/kenzok8/openwrt-daede /tmp/daed-src
		git -C /tmp/daed-src checkout 519c19312c8719513cf8a07f390ae2a273039eaa
		cp -a /tmp/daed-src/daed package/daed
		cp -a /tmp/daed-src/luci-app-daede package/luci-app-daede
		# luci-app-daede/Makefile:83 installs ../dae/files/dae.config (run 8
		# died on its absence); kenzok8 ships a dae/ dir -- copy it too.
		# Config does not select dae, so it is not built, only referenced.
		cp -a /tmp/daed-src/dae package/dae
		# Fallback only: kenzok8 also ships a vmlinux-btf/ dir, never copied.
		# With kernel BTF enabled (Configs/x86_64) daed's choice stays on the
		# integrated path and this package is not built; it only covers the
		# case where the choice falls to DAED_USE_VMLINUX_BTF.
		cp -a /tmp/daed-src/vmlinux-btf package/vmlinux-btf
		# kenzok8 519c193 (daed 2026.11.18) Build/Prepare hard-requires
		# package/ci/patches/dae-core/0001-keep-protocol-wrappers-in-tcp-relay.patch
		# (DAE_CORE_PATCH_DIR is $(CURDIR)/../ci/patches/dae-core; the
		# '@test -s' guard fails silently -- run 44650072855 died there
		# with no tar error, only make Error 1). The old pin 1eedcafd
		# (2026.10.30) had no such requirement, which is why earlier
		# runs passed. Copy only the patches subtree, not the whole ci/.
		mkdir -p package/ci
		cp -a /tmp/daed-src/ci/patches package/ci/patches
		[ -s package/ci/patches/dae-core/0001-keep-protocol-wrappers-in-tcp-relay.patch ] || { echo "ERROR: daed dae-core patch missing from kenzok8 clone"; exit 1; }
	
		# daed 2026.11.18 requires Go >= 1.27, but the 25.12 feed default is
		# 1.26 (run 6 died on 'go.mod requires go >= 1.27.0'). Point only
		# daed at the feed's versioned 1.27 host toolchain; everything else
		# keeps the default 1.26 it already built fine with in run 6.
		sed -i 's/^PKG_BUILD_DEPENDS:=golang\/host /PKG_BUILD_DEPENDS:=golang1.27\/host /' package/daed/Makefile
	fi # end daed (config-gated)

	# NOTE (2026-11-02, kenzok8 switch): the old fork-local fail-fast patch
	# (Scripts/patch_daed_makefile.py) is NOT applied here -- its anchors
	# (go get / .node_tmp) do not exist in kenzok8's tarball-only Prepare.
	# Applying it would fail this diy step outright. The script file stays
	# in the repo as dead code for now.

	# OpenClash UI (core downloads on first run -- accepted)
	# NOTE (2026-11-04, runs 11+12): full `git clone` of OpenClash
	# stalled twice (80-105 min no output, then fetch-pack disconnect
	# / early EOF, exit 128). Only the pinned commit's tree is used
	# (cp below), so fetch just that commit (depth 1 by SHA) with a
	# codeload-tarball fallback; tree is identical to checking out
	# the same commit from a full clone. Both paths fail fast.
	rm -rf /tmp/openclash-src /tmp/openclash.tar.gz
	git init -q /tmp/openclash-src
	git -C /tmp/openclash-src remote add origin https://github.com/vernesong/OpenClash
	if git -C /tmp/openclash-src fetch -q --depth 1 origin e553e82e01c697aefbe1555261a503f425e00ccd; then
		git -C /tmp/openclash-src checkout -q FETCH_HEAD
	else
		echo "SHA fetch failed, falling back to codeload tarball"
		rm -rf /tmp/openclash-src
		mkdir -p /tmp/openclash-src
		curl -fsSL -o /tmp/openclash.tar.gz https://codeload.github.com/vernesong/OpenClash/tar.gz/e553e82e01c697aefbe1555261a503f425e00ccd
		tar -xzf /tmp/openclash.tar.gz -C /tmp/openclash-src --strip-components=1
	fi
	cp -a /tmp/openclash-src/luci-app-openclash package/luci-app-openclash

	# Lucky UI + binary package (both dirs in the same pinned repo)
	# -- x86_64 (main router) ONLY, restored 2026-11-20 (user
	# decision: main router keeps Lucky). Removed from the AX6000
	# (NSS) config 2026-11-19 (user decision, to make room for the
	# OpenClash Meta core). It is NOT in any official 25.12 feed --
	# the old "packages come from the feeds" comment was wrong, and
	# run 44567316875 shipped without Lucky because defconfig
	# silently dropped the still-selected symbols. Pin 91b50662 is
	# the same as the 11-04 build that shipped Lucky 3.5.0-r1.
	if ! grep -q "^CONFIG_TARGET_qualcommax=y" .config 2>/dev/null; then
	git clone https://github.com/gdy666/luci-app-lucky /tmp/lucky-src
	git -C /tmp/lucky-src checkout 91b506627c1d81fa323816e3aeafcbde493d03a9
	cp -a /tmp/lucky-src/luci-app-lucky package/luci-app-lucky
	# luci-app-lucky declares +lucky, but only the UI dir was copied --
	# run 9 died at package/install on `lucky (no such package)`. The
	# sibling `lucky` binary package lives in the same pinned repo
	# (prebuilt release tarball, no build work); copy it too. Same
	# class of gap as run 9's dae/ sibling.
	cp -a /tmp/lucky-src/lucky package/lucky
	[ -d package/luci-app-lucky ] || { echo "ERROR: luci-app-lucky missing from tree"; exit 1; }
	[ -d package/lucky ] || { echo "ERROR: lucky missing from tree"; exit 1; }
	fi

	# Disk manager (Lua + luci-compat, which exists in the 25.12 luci feed)
	git clone https://github.com/lisaac/luci-app-diskman /tmp/diskman-src
	git -C /tmp/diskman-src checkout c20df1d4f40d86e32fd919f33122b2a48f8a99b4
	cp -a /tmp/diskman-src/applications/luci-app-diskman package/luci-app-diskman

	# RAM-free (JS)
	git clone https://github.com/sbwml/luci-app-ramfree /tmp/ramfree-src
	git -C /tmp/ramfree-src checkout 54dc42ded2e19f2f191b3ee54ac952f9d4acc8f4
	cp -a /tmp/ramfree-src package/luci-app-ramfree

	# OTA REMOVED 2026-11-19 (user decision): no clone, no copy;
	# Config no longer selects CONFIG_PACKAGE_luci-app-ota.

	# Scheduled reboot UI (Lua; f8q8's Makefile is package.mk-based
	# with an explicit install section -- it installs ./files/root/
	# directly, so unlike Wenjw28's luci.mk version there is NO
	# files/-ignored-by-luci.mk trap and NO restructure is needed.
	# ROOT CAUSE of the old +cron drop (2026-11-18, runs 44179668449
	# + 44237725082): Wenjw28's LUCI_DEPENDS named `+cron`, which is
	# not a package in OpenWrt main; an unsatisfiable dep makes the
	# symbol unselectable and defconfig drops the =y line silently.
	# f8q8's Makefile names NO deps at all, so instead of a sed we
	# ADD the deps the Lua UI needs on ucode LuCI: +luci-base (the
	# framework) + +luci-compat (Lua compat shim). Fail fast if the
	# insert does not apply. (Upstream source change 2026-11-21:
	# Wenjw28/luci-app-autoreboot is gone -- GitHub API 404, and git
	# ls-remote reproduces the runner's auth-prompt failure, which
	# killed run 44875269339 at the clone step. f8q8's repo is the
	# same package lineage: zxl78585's fork, renamed/transferred to
	# f8q8; the 4 files and the cron-reboot logic are identical,
	# only the files/ level differs (files/root/... vs files/...).
	# Pinned to its only commit d211e56, 2017-09-22.)
	git clone https://github.com/f8q8/luci-app-autoreboot /tmp/autoreboot-src
	git -C /tmp/autoreboot-src checkout d211e5681093967015bf87167fd54a09f0727f3e
	cp -a /tmp/autoreboot-src package/luci-app-autoreboot
	# f8q8 ships the same 4 files under files/root/ (not files/).
	# Fail fast if the layout changes (pinned commit d211e56 has
	# exactly these 4 files).
	[ "$(find package/luci-app-autoreboot/files -type f | wc -l)" -eq 4 ] || { echo "ERROR: autoreboot files/ layout changed (expected exactly 4 files)"; exit 1; }
	for f in root/etc/config/autoreboot root/etc/init.d/autoreboot root/usr/lib/lua/luci/controller/autoreboot.lua root/usr/lib/lua/luci/model/cbi/autoreboot.lua; do
		[ -f "package/luci-app-autoreboot/files/$f" ] || { echo "ERROR: autoreboot file missing: files/$f"; exit 1; }
	done
	# init script arrives 644 from git; INSTALL_BIN makes it 755 at
	# install time, but keep it executable in the tree too.
	chmod 755 package/luci-app-autoreboot/files/root/etc/init.d/autoreboot
	[ -x package/luci-app-autoreboot/files/root/etc/init.d/autoreboot ] || { echo "ERROR: autoreboot init script not executable"; exit 1; }
	# Deps the Lua UI needs on ucode LuCI (see comment above).
	sed -i 's|^\tPKGARCH:=all$|\tDEPENDS:=+luci-base +luci-compat\n\tPKGARCH:=all|' package/luci-app-autoreboot/Makefile
	grep -q "DEPENDS:=+luci-base +luci-compat" package/luci-app-autoreboot/Makefile || { echo "ERROR: autoreboot DEPENDS fix did not apply"; exit 1; }
	if grep -q "DEPENDS:=.*+cron" package/luci-app-autoreboot/Makefile; then echo "ERROR: autoreboot Makefile references +cron"; exit 1; fi
	# scan.mk only discovers a package whose OWN Makefile contains a
	# literal "call $(BuildPackage...)" line; f8q8's Makefile already
	# ends with $(eval $(call BuildPackage,luci-app-autoreboot)), so
	# no append is needed -- just fail fast if the line is absent.
	grep -q 'call BuildPackage' package/luci-app-autoreboot/Makefile || { echo "ERROR: autoreboot BuildPackage line missing"; exit 1; }

	# Scheduled reboot UI text (2026-11-19, user decision): f8q8's
	# menu name is already Chinese ("定时重启"); its description is
	# the generic "配置定时重启。" with no wrong hardware/branch
	# name. Keep the menu-name fix as a no-op guard (it still fixes
	# an upstream revert to English), and put the device name into
	# the description. Fail fast if either sed does not match.
	sed -i 's/_("Scheduled Reboot")/_("定时重启")/' package/luci-app-autoreboot/files/root/usr/lib/lua/luci/controller/autoreboot.lua
	grep -q '_("定时重启")' package/luci-app-autoreboot/files/root/usr/lib/lua/luci/controller/autoreboot.lua || { echo "ERROR: autoreboot menu name fix did not apply"; exit 1; }
	if grep -q 'Scheduled Reboot' package/luci-app-autoreboot/files/root/usr/lib/lua/luci/controller/autoreboot.lua; then echo "ERROR: autoreboot controller still contains Scheduled Reboot"; exit 1; fi
	# Description names the device: AX6000 (NSS fork) keeps its device
	# name; x86_64 (main router) and other targets get generic text.
	if grep -q "^CONFIG_TARGET_qualcommax=y" .config 2>/dev/null; then
		sed -i 's|配置定时重启。|小米 AX6000 定时重启插件。|' package/luci-app-autoreboot/files/root/usr/lib/lua/luci/model/cbi/autoreboot.lua
		grep -q '小米 AX6000 定时重启插件' package/luci-app-autoreboot/files/root/usr/lib/lua/luci/model/cbi/autoreboot.lua || { echo "ERROR: autoreboot description fix did not apply"; exit 1; }
	else
		sed -i 's|配置定时重启。|定时重启插件|' package/luci-app-autoreboot/files/root/usr/lib/lua/luci/model/cbi/autoreboot.lua
		grep -q '定时重启插件' package/luci-app-autoreboot/files/root/usr/lib/lua/luci/model/cbi/autoreboot.lua || { echo "ERROR: autoreboot description fix did not apply"; exit 1; }
	fi
	if grep -q 'MT7987A' package/luci-app-autoreboot/files/root/usr/lib/lua/luci/model/cbi/autoreboot.lua; then echo "ERROR: autoreboot CBI still contains MT7987A"; exit 1; fi

	# cloudflared: NOT cloned here (it comes from the feeds). It was
	# removed from the AX6000 (NSS) config 2026-11-19 (user decision,
	# to make room for the OpenClash Meta core). Configs/x86_64 (main
	# router) still selects CONFIG_PACKAGE_cloudflared per user
	# decision 2026-11-20 (kept as-is).

	# Mount Points + Plugins menu entries (2026-11-19, mounts-fix +
	# plugins-hide, user decision) -- AX6000 (qualcommax) ONLY.
	# This build deletes block-mount (AX6000 has no USB port), so
	# /sbin/block is gone and the LuCI Mount Points page
	# (admin/system/mounts) fails when opened; and the Plugins page
	# (admin/system/plugins) is unused clutter. x86_64 (main router)
	# HAS USB + block-mount, so Mount Points stays and the Plugins
	# page is left alone; the 25.12 feed menu entry count also
	# differs from the NSS 15, so the check below would fail there.
	# Hide both menu entries via the standard buildroot files/
	# overlay (same role as ImageBuilder FILES= for the AX3000T
	# oc48007 fix): files/ is copied into the target rootfs after
	# package files, so it overrides luci-mod-system's menu JSON.
	# The overlay is vendored at Files-ax6000/ and derived from the
	# NSS tree's own menu file (15 entries) by deleting ONLY the
	# mounts and plugins blocks -- do NOT reuse the AX3000T 12-entry
	# file, the 24.10 menu lacks the pwpolicy entry the NSS menu has.
	# Fail fast if the feed file drifts (upstream restructuring must
	# abort here, not ship a stale menu).
	if grep -q "^CONFIG_TARGET_qualcommax=y" .config 2>/dev/null; then
	mkdir -p files/usr/share/luci/menu.d
	cp -a "$GITHUB_WORKSPACE/Files-ax6000/usr/share/luci/menu.d/luci-mod-system.json" files/usr/share/luci/menu.d/luci-mod-system.json
	[ -f files/usr/share/luci/menu.d/luci-mod-system.json ] || { echo "ERROR: mounts menu overlay missing from tree files/"; exit 1; }
	FEED_MENU=$(find feeds -path '*luci-mod-system*menu.d/luci-mod-system.json' -type f 2>/dev/null)
	[ "$(printf '%s' "$FEED_MENU" | grep -c .)" -eq 1 ] || { echo "ERROR: expected exactly 1 luci-mod-system menu file under feeds, got: $FEED_MENU"; exit 1; }
	python3 - "$FEED_MENU" files/usr/share/luci/menu.d/luci-mod-system.json <<'PYEOF'
import json, sys
feed_path, overlay_path = sys.argv[1], sys.argv[2]
with open(feed_path) as f:
    feed = json.load(f)
with open(overlay_path) as f:
    overlay = json.load(f)
assert 'admin/system/mounts' in feed, 'feed menu has no mounts entry (upstream changed?)'
assert 'admin/system/plugins' in feed, 'feed menu has no plugins entry (upstream changed?)'
assert len(feed) == 15, 'feed menu entry count changed: %d (expected 15)' % len(feed)
expected = {k: v for k, v in feed.items() if k not in ('admin/system/mounts', 'admin/system/plugins')}
assert overlay == expected, 'overlay is not exactly feed-minus-mounts-minus-plugins (upstream drift?)'
assert len(overlay) == 13, 'overlay entry count: %d (expected 13)' % len(overlay)
blob = open(overlay_path, 'rb').read()
assert b'mounts' not in blob and b'/sbin/block' not in blob and b'plugins' not in blob, 'overlay still mentions mounts, plugins or /sbin/block'
print('menu overlay check OK: feed 15 entries -> overlay 13, mounts + plugins + /sbin/block gone')
PYEOF
	fi # end AX6000-only menu overlay

	# LED night-off timer + default timezone (2026-11-19, user request)
	# -- AX6000 (qualcommax) ONLY. Bake the LED scripts/crontab and
	# first-boot scripts into the image via the standard buildroot
	# files/ overlay (same mechanism as the mounts menu fix above).
	# files/ is copied into the target rootfs after package files.
	# No credentials here: the LED scripts only write LED brightness
	# nodes, the crontab only schedules them, 99-set-timezone only
	# sets timezone/zonename, and 99-firstboot-init only applies the
	# production LAN (192.168.2.5) + hostname when the LAN is still
	# the build default (factory state); it exits without
	# touching anything when settings were preserved. x86_64 (main
	# router) has no such LED nodes and its timezone is already set
	# via config, so this whole block is skipped there to keep the
	# image identical to the current one.
	# Fail fast if any vendored file is missing or its content drifts.
	if grep -q "^CONFIG_TARGET_qualcommax=y" .config 2>/dev/null; then
	mkdir -p files/root files/etc/crontabs files/etc/uci-defaults files/etc/config files/usr/share/pbr
	cp -a "$GITHUB_WORKSPACE/Files-ax6000/root/led-night.sh" files/root/led-night.sh
	cp -a "$GITHUB_WORKSPACE/Files-ax6000/root/led-day.sh" files/root/led-day.sh
	cp -a "$GITHUB_WORKSPACE/Files-ax6000/etc/crontabs/root" files/etc/crontabs/root
	cp -a "$GITHUB_WORKSPACE/Files-ax6000/etc/uci-defaults/99-set-timezone" files/etc/uci-defaults/99-set-timezone
	cp -a "$GITHUB_WORKSPACE/Files-ax6000/etc/uci-defaults/99-firstboot-init" files/etc/uci-defaults/99-firstboot-init
	# Static wireless (psk2, NO key -- password entered in LuCI after flashing),
	# disabled-by-default WARP WireGuard interface, and pbr split-tunnel
	# config + China-list user file (all added 2026-11-21, user decision).
	cp -a "$GITHUB_WORKSPACE/Files-ax6000/etc/config/wireless" files/etc/config/wireless
	cp -a "$GITHUB_WORKSPACE/Files-ax6000/etc/uci-defaults/99-wireguard-warp" files/etc/uci-defaults/99-wireguard-warp
	cp -a "$GITHUB_WORKSPACE/Files-ax6000/etc/config/pbr" files/etc/config/pbr
	cp -a "$GITHUB_WORKSPACE/Files-ax6000/usr/share/pbr/pbr.user.china.uc" files/usr/share/pbr/pbr.user.china.uc
	chmod 755 files/root/led-night.sh files/root/led-day.sh files/etc/uci-defaults/99-set-timezone files/etc/uci-defaults/99-firstboot-init files/etc/uci-defaults/99-wireguard-warp
	for f in root/led-night.sh root/led-day.sh etc/crontabs/root etc/uci-defaults/99-set-timezone etc/uci-defaults/99-firstboot-init etc/config/wireless etc/uci-defaults/99-wireguard-warp etc/config/pbr usr/share/pbr/pbr.user.china.uc; do
		[ -f "files/$f" ] || { echo "ERROR: LED/timezone overlay missing from tree files/: $f"; exit 1; }
	done
	[ -x files/root/led-night.sh ] || { echo "ERROR: led-night.sh not executable in tree files/"; exit 1; }
	[ -x files/root/led-day.sh ] || { echo "ERROR: led-day.sh not executable in tree files/"; exit 1; }
	[ -x files/etc/uci-defaults/99-set-timezone ] || { echo "ERROR: 99-set-timezone not executable in tree files/"; exit 1; }
	[ -x files/etc/uci-defaults/99-firstboot-init ] || { echo "ERROR: 99-firstboot-init not executable in tree files/"; exit 1; }
	[ -x files/etc/uci-defaults/99-wireguard-warp ] || { echo "ERROR: 99-wireguard-warp not executable in tree files/"; exit 1; }
	[ "$(wc -l < files/root/led-night.sh)" -eq 7 ] || { echo "ERROR: led-night.sh line count changed (expected 7)"; exit 1; }
	[ "$(wc -l < files/root/led-day.sh)" -eq 2 ] || { echo "ERROR: led-day.sh line count changed (expected 2)"; exit 1; }
	[ "$(wc -l < files/etc/crontabs/root)" -eq 2 ] || { echo "ERROR: crontab line count changed (expected 2)"; exit 1; }
	grep -Fq "0 22 * * * /root/led-night.sh" files/etc/crontabs/root || { echo "ERROR: crontab missing 22:00 night line"; exit 1; }
	grep -Fq "0 7 * * * /root/led-day.sh" files/etc/crontabs/root || { echo "ERROR: crontab missing 07:00 day line"; exit 1; }
	grep -q "blue:power" files/root/led-night.sh || { echo "ERROR: led-night.sh missing blue:power"; exit 1; }
	grep -q "blue:power" files/root/led-day.sh || { echo "ERROR: led-day.sh missing blue:power"; exit 1; }
	grep -q "timezone='CST-8'" files/etc/uci-defaults/99-set-timezone || { echo "ERROR: timezone script missing CST-8"; exit 1; }
	grep -q "zonename='Asia/Shanghai'" files/etc/uci-defaults/99-set-timezone || { echo "ERROR: timezone script missing Asia/Shanghai"; exit 1; }
	grep -q "uci commit system" files/etc/uci-defaults/99-set-timezone || { echo "ERROR: timezone script missing uci commit"; exit 1; }
	grep -q "192.168.2.5" files/etc/uci-defaults/99-firstboot-init || { echo "ERROR: firstboot-init missing production LAN 192.168.2.5"; exit 1; }
	! grep -q "192.168.2.209" files/etc/uci-defaults/99-firstboot-init || { echo "ERROR: firstboot-init still contains old LAN 192.168.2.209"; exit 1; }
	grep -q "hostname='ax6000'" files/etc/uci-defaults/99-firstboot-init || { echo "ERROR: firstboot-init missing hostname ax6000"; exit 1; }
	grep -Fq '"$LAN_IP" = "192.168.2.1"' files/etc/uci-defaults/99-firstboot-init || { echo "ERROR: firstboot-init missing factory-state guard (LAN 192.168.2.1)"; exit 1; }
	# Static wireless: SSIDs 5G/2.4G/5G, channels 36/1/36, psk2, NO key line.
	grep -q "option ssid '5G'" files/etc/config/wireless || { echo "ERROR: wireless missing SSID 5G"; exit 1; }
	grep -q "option ssid '2.4G'" files/etc/config/wireless || { echo "ERROR: wireless missing SSID 2.4G"; exit 1; }
	grep -q "option encryption 'psk2'" files/etc/config/wireless || { echo "ERROR: wireless missing psk2"; exit 1; }
	! grep -q "option key" files/etc/config/wireless || { echo "ERROR: wireless contains a key line (password must never enter firmware)"; exit 1; }
	# WARP interface: disabled by default, no default route via WG.
	grep -q "network.warp.disabled='1'" files/etc/uci-defaults/99-wireguard-warp || { echo "ERROR: 99-wireguard-warp missing disabled=1"; exit 1; }
	grep -q "route_allowed_ips='0'" files/etc/uci-defaults/99-wireguard-warp || { echo "ERROR: 99-wireguard-warp missing route_allowed_ips=0"; exit 1; }
	grep -q "network.warp_peer=wireguard_warp" files/etc/uci-defaults/99-wireguard-warp || { echo "ERROR: 99-wireguard-warp missing warp peer section"; exit 1; }
	# pbr split tunnel: China direct via wan, foreign via warp.
	grep -q "option interface 'warp'" files/etc/config/pbr || { echo "ERROR: pbr config missing warp policy"; exit 1; }
	grep -q "pbr.user.china.uc" files/etc/config/pbr || { echo "ERROR: pbr config missing China user file include"; exit 1; }
	grep -q "china_ip_list" files/usr/share/pbr/pbr.user.china.uc || { echo "ERROR: pbr.user.china.uc missing China list URL"; exit 1; }
	echo "LED/timezone overlay check OK: 9 files in tree files/, scripts executable, content verified"
	fi # end AX6000-only LED/timezone overlay

	# OpenClash Meta core (2026-11-19, user decision) -- AX6000
	# (qualcommax) ONLY: bake the mihomo binary into the image so
	# OpenClash works out of the box (the core was missing; 5.1M
	# overlay could never hold it). Downloaded here at build time
	# (pinned release, hash-verified) into the tree files/ overlay
	# at the path OpenClash expects (/etc/openclash/core/clash_meta,
	# per luci-app-openclash openclash_core.sh: meta_core_path).
	# Source: MetaCubeX/mihomo Prerelease-Alpha 100ff73 linux-arm64.
	# (Updated 2026-11-21 from v1.19.34; same 57,344,126 B size.) The binary is
	# NOT vendored in the repo (57M is too large for the git-data API
	# push; it is fetched here like the other externals). Fail fast
	# if the download, the .gz hash, the size, the arch, or the
	# binary hash does not match. Space: Lucky (~14M,
	# incompressible) + cloudflared (~25M) removed frees ~39M
	# uncompressed; mihomo is 57,344,126 B uncompressed but
	# xz-compresses to ~13.7M, so the squashfs SHRINKS ~7M and fits
	# the 70.6M rootfs UBI volume with room to spare.
	# x86_64 (main router) is amd64, NOT arm64: the arm64 binary
	# cannot run there. Skip this block on x86_64; OpenClash keeps
	# its previous behavior of downloading the correct-arch core on
	# first run (as the current production firmware does).
	if grep -q "^CONFIG_TARGET_qualcommax=y" .config 2>/dev/null; then
	mkdir -p files/etc/openclash/core
	MIHOMO_URL="https://github.com/MetaCubeX/mihomo/releases/download/Prerelease-Alpha/mihomo-linux-arm64-alpha-100ff73.gz"
	MIHOMO_GZ_SHA256="8e5dc782ce5a64a59584c31fde53168004889c99ec40e19758e2e9ad73b03f65"
	curl -fsSL -o mihomo-linux-arm64-alpha-100ff73.gz "$MIHOMO_URL" || { echo "ERROR: mihomo download failed"; exit 1; }
	echo "$MIHOMO_GZ_SHA256  mihomo-linux-arm64-alpha-100ff73.gz" | sha256sum -c - || { echo "ERROR: mihomo .gz SHA256 mismatch"; exit 1; }
	gzip -dc mihomo-linux-arm64-alpha-100ff73.gz > files/etc/openclash/core/clash_meta || { echo "ERROR: mihomo gunzip failed"; exit 1; }
	chmod 755 files/etc/openclash/core/clash_meta
	rm -f mihomo-linux-arm64-alpha-100ff73.gz
	[ -f files/etc/openclash/core/clash_meta ] || { echo "ERROR: clash_meta missing from tree files/"; exit 1; }
	[ -x files/etc/openclash/core/clash_meta ] || { echo "ERROR: clash_meta not executable in tree files/"; exit 1; }
	[ "$(wc -c < files/etc/openclash/core/clash_meta)" -eq 57344126 ] || { echo "ERROR: clash_meta size changed (expected 57344126)"; exit 1; }
	echo "aa782da8db1236f0253cd34b87c5a95c833fe4c6f308053cb83fcb62d059efba  files/etc/openclash/core/clash_meta" | sha256sum -c - || { echo "ERROR: clash_meta SHA256 mismatch"; exit 1; }
	file files/etc/openclash/core/clash_meta | grep -q "ARM aarch64" || { echo "ERROR: clash_meta is not ARM aarch64 ELF"; exit 1; }
	file files/etc/openclash/core/clash_meta | grep -q "ELF 64-bit" || { echo "ERROR: clash_meta is not 64-bit ELF"; exit 1; }
	echo "Meta core check OK: clash_meta 57344126 B, aarch64 ELF, SHA256 verified"
	fi # end AX6000-only mihomo arm64 core
}
