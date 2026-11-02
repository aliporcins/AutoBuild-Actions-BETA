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
	# it needs no clone here.

	# Defensive: official 25.12 feeds ship no daed, but drop any feed copy
	# if one ever appears, so the pinned QiuSimons copy is the only one.
	rm -rf feeds/packages/net/daed feeds/luci/applications/luci-app-daed

	# daed (dae + wing) + luci-app-daed UI -- QiuSimons, 2026-09-04
	git clone https://github.com/QiuSimons/luci-app-daed /tmp/daed-src
	git -C /tmp/daed-src checkout bc9a40e08b3c926a4d324f87911cba5e85dce8e6
	cp -a /tmp/daed-src/daed package/daed
	cp -a /tmp/daed-src/luci-app-daed package/luci-app-daed

	# Fork-local fail-fast for QiuSimons daed Build/Prepare (2026-11-02):
	# upstream Prepare is ';'-chained, so a failed node download, pnpm
	# install, pnpm build or cp is silently swallowed and only surfaces
	# hours later as a Go embed error on an empty webrender/web
	# (runs 2 and 3 both died this way; the frontend itself builds fine).
	# Patch it to abort loudly instead. The patch script asserts its
	# anchors, so a future upstream Makefile change fails here at diy
	# time rather than silently skipping the patch.
	python3 $GITHUB_WORKSPACE/Scripts/patch_daed_makefile.py package/daed/Makefile

	# OpenClash UI (core downloads on first run -- accepted)
	git clone https://github.com/vernesong/OpenClash /tmp/openclash-src
	git -C /tmp/openclash-src checkout e553e82e01c697aefbe1555261a503f425e00ccd
	cp -a /tmp/openclash-src/luci-app-openclash package/luci-app-openclash

	# Lucky UI + binary (binary fetched from upstream release at build time
	# by the package's own Makefile)
	git clone https://github.com/gdy666/luci-app-lucky /tmp/lucky-src
	git -C /tmp/lucky-src checkout 91b506627c1d81fa323816e3aeafcbde493d03a9
	cp -a /tmp/lucky-src/luci-app-lucky package/luci-app-lucky

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
	git clone https://github.com/Wenjw28/luci-app-autoreboot /tmp/autoreboot-src
	git -C /tmp/autoreboot-src checkout 53f6e73bfe8b5416a4e602791870c0d6e0f0920c
	cp -a /tmp/autoreboot-src package/luci-app-autoreboot
	sed -i 's/LUCI_DEPENDS:=+cron +luci-base/LUCI_DEPENDS:=+cron +luci-base +luci-compat/' package/luci-app-autoreboot/Makefile
}
