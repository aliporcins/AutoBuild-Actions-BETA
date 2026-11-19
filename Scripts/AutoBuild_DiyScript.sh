#!/bin/bash
# AutoBuild Module by Hyy2001 <https://github.com/Hyy2001X/AutoBuild-Actions-BETA>
# AutoBuild DiyScript -- adapted for aliporcins/AutoBuild-Actions-BETA:
# builds official openwrt-25.12 for x86_64 with the production VM100 package set.
# No credentials are baked into the image; default address stays 192.168.1.1.

Firmware_Diy_Core() {

	Author=AUTO
	# 作者名称, AUTO: [自动识别]

	Author_URL=AUTO
	# 自定义作者网站或域名, AUTO: [自动识别]

	Default_Flag=AUTO
	# 固件标签 (名称后缀), 适用不同配置文件, AUTO: [自动识别]

	Default_IP="192.168.1.1"
	# 固件 IP 地址 (upstream default; production 192.168.2.1 is NEVER baked in)

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
	# package/luci-app-totp is vendored in this repo (user's own package);
	# it needs no clone here -- BUT it does need copying into the tree:
	# the repo's package/ dir is not the openwrt tree's package/ dir, and
	# nothing else copies it, so make defconfig silently dropped
	# CONFIG_PACKAGE_luci-app-totp and every NSS build so far shipped
	# without TOTP (found 2026-11-18). Copy it like the other externals.
	cp -a $GITHUB_WORKSPACE/package/luci-app-totp package/luci-app-totp
	[ -d package/luci-app-totp ] || { echo "ERROR: vendored luci-app-totp missing from tree"; exit 1; }

	# Defensive: official 25.12 feeds ship no daed, but drop any feed copy
	# if one ever appears, so the pinned kenzok8 copy is the only one.
	rm -rf feeds/packages/net/daed feeds/luci/applications/luci-app-daed

	# daed (dae + wing) + luci-app-daede UI -- kenzok8, pinned 2026-11-02
	# (switched from QiuSimons after runs 2-5 died in its Build/Prepare:
	# ';'-chained pnpm web build, then missing system Go for go get).
	# kenzok8's daed/Makefile Prepare only unpacks a CI prebuilt tarball
	# (PKG_VERSION 2026.10.30, PKG_HASH 1850c01d...), no go get / pnpm.
	git clone https://github.com/kenzok8/openwrt-daede /tmp/daed-src
	git -C /tmp/daed-src checkout 1eedcafd1cd4d8a89ac928be6608df76ffb38f78
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

	# daed 2026.10.30 requires Go >= 1.27, but the 25.12 feed default is
	# 1.26 (run 6 died on 'go.mod requires go >= 1.27.0'). Point only
	# daed at the feed's versioned 1.27 host toolchain; everything else
	# keeps the default 1.26 it already built fine with in run 6.
	sed -i 's/^PKG_BUILD_DEPENDS:=golang\/host /PKG_BUILD_DEPENDS:=golang1.27\/host /' package/daed/Makefile

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
	git clone https://github.com/gdy666/luci-app-lucky /tmp/lucky-src
	git -C /tmp/lucky-src checkout 91b506627c1d81fa323816e3aeafcbde493d03a9
	cp -a /tmp/lucky-src/luci-app-lucky package/luci-app-lucky
	# luci-app-lucky declares +lucky, but only the UI dir was copied --
	# run 9 died at package/install on `lucky (no such package)`. The
	# sibling `lucky` binary package lives in the same pinned repo
	# (prebuilt release tarball, no build work); copy it too. Same
	# class of gap as run 9's dae/ sibling.
	cp -a /tmp/lucky-src/lucky package/lucky

	# Disk manager (Lua + luci-compat, which exists in the 25.12 luci feed)
	git clone https://github.com/lisaac/luci-app-diskman /tmp/diskman-src
	git -C /tmp/diskman-src checkout c20df1d4f40d86e32fd919f33122b2a48f8a99b4
	cp -a /tmp/diskman-src/applications/luci-app-diskman package/luci-app-diskman

	# RAM-free (JS)
	git clone https://github.com/sbwml/luci-app-ramfree /tmp/ramfree-src
	git -C /tmp/ramfree-src checkout 54dc42ded2e19f2f191b3ee54ac952f9d4acc8f4
	cp -a /tmp/ramfree-src package/luci-app-ramfree

	# OTA (JS, claims 25.12/apk support)
	git clone https://github.com/MinimaxFlora/luci-app-ota /tmp/ota-src
	git -C /tmp/ota-src checkout 5f66f5dc27bf9ec9d4666cc07f69d9b5ed1829d2
	cp -a /tmp/ota-src package/luci-app-ota

	# Scheduled reboot UI (Lua; upstream has no luci-compat dep, add it
	# fork-locally so it renders on ucode LuCI; its function is one cron
	# line if it still fails Phase 1 verification)
	# ROOT CAUSE (2026-11-18, run 44179668449 + 44237725082 logs): the
	# package was cloned/copied fine but `make defconfig` silently
	# dropped CONFIG_PACKAGE_luci-app-autoreboot -- its LUCI_DEPENDS
	# named `+cron`, which is not a package in OpenWrt main (no
	# standalone cron package exists; crond/crontab come from busybox,
	# and no package in the luci feed depends on +cron). An
	# unsatisfiable dep makes the symbol unselectable and defconfig
	# drops the =y line with no warning. Fix: drop +cron (busybox
	# already provides crond), keep +luci-compat. Fail fast if the
	# sed does not match (upstream reordering the line must not
	# silently reintroduce the drop).
	git clone https://github.com/Wenjw28/luci-app-autoreboot /tmp/autoreboot-src
	git -C /tmp/autoreboot-src checkout 53f6e73bfe8b5416a4e602791870c0d6e0f0920c
	cp -a /tmp/autoreboot-src package/luci-app-autoreboot
	# ROOT CAUSE #3 (2026-11-18, run 44265325657): upstream ships all 4
	# files under files/ (files/etc/config, files/etc/init.d,
	# files/usr/lib/lua/luci/controller, files/usr/lib/lua/luci/model/cbi),
	# but luci.mk only installs luasrc/, ucode/, htdocs/ and root/ --
	# files/ is silently ignored, so the package built EMPTY (apk db I:1,
	# zero files) while the symbol and the config checks all passed.
	# Restructure files/ into luci.mk layout, mirroring vendored
	# luci-app-totp (luasrc/ + root/). Fail fast if upstream's files/
	# layout changes (pinned commit 53f6e73 has exactly these 4 files).
	[ "$(find package/luci-app-autoreboot/files -type f | wc -l)" -eq 4 ] || { echo "ERROR: autoreboot files/ layout changed (expected exactly 4 files)"; exit 1; }
	mkdir -p package/luci-app-autoreboot/luasrc/controller package/luci-app-autoreboot/luasrc/model/cbi package/luci-app-autoreboot/root/etc/config package/luci-app-autoreboot/root/etc/init.d
	mv package/luci-app-autoreboot/files/usr/lib/lua/luci/controller/autoreboot.lua package/luci-app-autoreboot/luasrc/controller/
	mv package/luci-app-autoreboot/files/usr/lib/lua/luci/model/cbi/autoreboot.lua package/luci-app-autoreboot/luasrc/model/cbi/
	mv package/luci-app-autoreboot/files/etc/config/autoreboot package/luci-app-autoreboot/root/etc/config/
	mv package/luci-app-autoreboot/files/etc/init.d/autoreboot package/luci-app-autoreboot/root/etc/init.d/
	# init script arrives 664 from git; it must be executable or procd
	# cannot run it and `autoreboot enable` creates no rc.d symlink.
	chmod 755 package/luci-app-autoreboot/root/etc/init.d/autoreboot
	rm -rf package/luci-app-autoreboot/files
	for f in luasrc/controller/autoreboot.lua luasrc/model/cbi/autoreboot.lua root/etc/config/autoreboot root/etc/init.d/autoreboot; do
		[ -f "package/luci-app-autoreboot/$f" ] || { echo "ERROR: autoreboot file missing after restructure: $f"; exit 1; }
	done
	[ -x package/luci-app-autoreboot/root/etc/init.d/autoreboot ] || { echo "ERROR: autoreboot init script not executable"; exit 1; }
	[ ! -e package/luci-app-autoreboot/files ] || { echo "ERROR: autoreboot files/ still present after restructure"; exit 1; }
	sed -i 's/LUCI_DEPENDS:=+cron +luci-base/LUCI_DEPENDS:=+luci-base +luci-compat/' package/luci-app-autoreboot/Makefile
	grep -q "LUCI_DEPENDS:=+luci-base +luci-compat" package/luci-app-autoreboot/Makefile || { echo "ERROR: autoreboot LUCI_DEPENDS fix did not apply"; exit 1; }
	if grep -q "LUCI_DEPENDS:=.*+cron" package/luci-app-autoreboot/Makefile; then echo "ERROR: autoreboot Makefile still references +cron"; exit 1; fi
	# ROOT CAUSE #2 (2026-11-18, runs 44255529707 + 44261474673 DIAG):
	# even with +cron fixed, the package was invisible to Kconfig -- its
	# symbol never appears in tmp/.config-package.in. include/scan.mk
	# only discovers a package whose OWN Makefile contains a literal
	# "call $(BuildPackage...)" line (grep over package/*/Makefile);
	# upstream's Makefile ends at "include .../luci.mk" and has no such
	# line -- luci.mk:404 does call BuildPackage (LUCI_BUILD_PACKAGES :=
	# $(PKG_NAME)), but the scanner never reads luci.mk. Every other
	# external package here carries the line (diskman/ramfree/ota as a
	# comment, totp as comment + eval). Add both, mirroring totp.
	# Without this, make defconfig silently drops the symbol no matter
	# what the Config file requests. Fail fast if the line is absent.
	echo "" >> package/luci-app-autoreboot/Makefile
	echo "# call BuildPackage - OpenWrt buildroot signature" >> package/luci-app-autoreboot/Makefile
	echo '$(eval $(call BuildPackage,$(PKG_NAME)))' >> package/luci-app-autoreboot/Makefile
	grep -q 'call BuildPackage' package/luci-app-autoreboot/Makefile || { echo "ERROR: autoreboot BuildPackage line did not apply"; exit 1; }

	# cloudflared 2026.10.7 -> 2026.11.1 (upstream release 2026-11-17;
	# feed still at 2026.10.7 as of 2026-11-18). Bump the feed Makefile
	# in place; the feed's Go is 1.27.4 which satisfies go.mod's
	# `go 1.27.4`, so no toolchain change is needed. Remove this block
	# once the feed passes 2026.11.1. Fail fast if the sed does not match.
	sed -i 's/^PKG_VERSION:=.*/PKG_VERSION:=2026.11.1/' feeds/packages/net/cloudflared/Makefile
	sed -i 's/^PKG_HASH:=.*/PKG_HASH:=d72ba7465d392a7c82be85e9417c0c923aa69e7c6dbc9baaeb42bb49a8f0572d/' feeds/packages/net/cloudflared/Makefile
	grep -q "^PKG_VERSION:=2026.11.1" feeds/packages/net/cloudflared/Makefile || { echo "ERROR: cloudflared version bump did not apply"; exit 1; }
	grep -q "^PKG_HASH:=d72ba7465d392a7c82be85e9417c0c923aa69e7c6dbc9baaeb42bb49a8f0572d" feeds/packages/net/cloudflared/Makefile || { echo "ERROR: cloudflared hash bump did not apply"; exit 1; }

	# Mount Points menu entry (2026-11-19, mounts-fix): this build
	# deletes block-mount (AX6000 has no USB port), so /sbin/block is
	# gone and the LuCI Mount Points page (admin/system/mounts) fails
	# when opened. Hide the menu entry via the standard buildroot
	# files/ overlay (same role as ImageBuilder FILES= for the
	# AX3000T oc48007 fix): files/ is copied into the target rootfs
	# after package files, so it overrides luci-mod-system's menu
	# JSON. The overlay is vendored at Files-ax6000/ and derived from
	# the NSS tree's own menu file (15 entries) by deleting ONLY the
	# mounts block -- do NOT reuse the AX3000T 12-entry file, the
	# 24.10 menu lacks the pwpolicy/plugins entries the NSS menu has.
	# Fail fast if the feed file drifts (upstream restructuring must
	# abort here, not ship a stale menu).
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
assert len(feed) == 15, 'feed menu entry count changed: %d (expected 15)' % len(feed)
expected = {k: v for k, v in feed.items() if k != 'admin/system/mounts'}
assert overlay == expected, 'overlay is not exactly feed-minus-mounts (upstream drift?)'
assert len(overlay) == 14, 'overlay entry count: %d (expected 14)' % len(overlay)
blob = open(overlay_path, 'rb').read()
assert b'mounts' not in blob and b'/sbin/block' not in blob, 'overlay still mentions mounts or /sbin/block'
print('menu overlay check OK: feed 15 entries -> overlay 14, mounts + /sbin/block gone')
PYEOF

	# LED night-off timer + default timezone (2026-11-19, user request):
	# bake the LED scripts/crontab and a first-boot timezone script
	# into the image via the standard buildroot files/ overlay (same
	# mechanism as the mounts menu fix above). files/ is copied into
	# the target rootfs after package files. No credentials here: the
	# LED scripts only write LED brightness nodes, the crontab only
	# schedules them, and the uci-defaults script only sets
	# timezone/zonename (hostname and LAN IP are set by config_generate
	# from the build inputs and are NOT touched).
	# Fail fast if any vendored file is missing or its content drifts.
	mkdir -p files/root files/etc/crontabs files/etc/uci-defaults
	cp -a "$GITHUB_WORKSPACE/Files-ax6000/root/led-night.sh" files/root/led-night.sh
	cp -a "$GITHUB_WORKSPACE/Files-ax6000/root/led-day.sh" files/root/led-day.sh
	cp -a "$GITHUB_WORKSPACE/Files-ax6000/etc/crontabs/root" files/etc/crontabs/root
	cp -a "$GITHUB_WORKSPACE/Files-ax6000/etc/uci-defaults/99-set-timezone" files/etc/uci-defaults/99-set-timezone
	chmod 755 files/root/led-night.sh files/root/led-day.sh files/etc/uci-defaults/99-set-timezone
	for f in root/led-night.sh root/led-day.sh etc/crontabs/root etc/uci-defaults/99-set-timezone; do
		[ -f "files/$f" ] || { echo "ERROR: LED/timezone overlay missing from tree files/: $f"; exit 1; }
	done
	[ -x files/root/led-night.sh ] || { echo "ERROR: led-night.sh not executable in tree files/"; exit 1; }
	[ -x files/root/led-day.sh ] || { echo "ERROR: led-day.sh not executable in tree files/"; exit 1; }
	[ -x files/etc/uci-defaults/99-set-timezone ] || { echo "ERROR: 99-set-timezone not executable in tree files/"; exit 1; }
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
	echo "LED/timezone overlay check OK: 4 files in tree files/, scripts executable, content verified"
}
