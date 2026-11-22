#!/usr/bin/env lua
-- sing-box 订阅自动更新（cron 每天 04:00 调）：拉取全部订阅并重建节点。
-- 全部失败或 0 节点时不改配置（保旧配置）；成功后若服务在运行则重启生效。
-- 日志追加到 /tmp/sing-box-sub-refresh.log。
local ok, mod = pcall(require, "luci.controller.sing-box")
local logf = io.open("/tmp/sing-box-sub-refresh.log", "a")
local function log(msg)
	local line = os.date("%Y-%m-%d %H:%M:%S") .. " " .. msg .. "\n"
	if logf then logf:write(line) end
end
if not ok or not mod or not mod.refresh_all_subscriptions then
	log("自动刷新失败：无法加载控制器模块。")
	if logf then logf:close() end
	os.exit(1)
end
local ok2, err, stats, failed, zero, preserved = mod.refresh_all_subscriptions()
if not ok2 then
	local msg = "自动刷新失败：" .. (err or "未知错误")
	if zero and #zero > 0 then msg = msg .. "（0 节点订阅：" .. table.concat(zero, "、") .. "）" end
	log(msg)
	if logf then logf:close() end
	os.exit(1)
end
local msg = "自动刷新成功：共 " .. tostring(stats.total) .. " 个节点"
if failed and #failed > 0 then msg = msg .. "，失败订阅：" .. table.concat(failed, "、") end
if zero and #zero > 0 then msg = msg .. "，0 节点订阅：" .. table.concat(zero, "、") end
if preserved then
	local pp = {}
	for tag, n in pairs(preserved) do pp[#pp + 1] = tag .. " " .. n .. " 个旧节点" end
	if #pp > 0 then msg = msg .. "，已保留：" .. table.concat(pp, "、") end
end
log(msg)
-- 服务在运行才重启生效；重启时保留开机自启设置（init 脚本在 enabled=0 时
-- start 直接返回 0 且不启动，裸 restart 会把服务停掉且不再起来）。
local function restart_preserve_autostart()
	-- 读当前自启值（直接读配置文件，不用 io.popen——路由器 Lua 的 io.popen 读不到输出）
	local enabled = "0"
	do
		local f = io.open("/etc/config/sing-box", "r")
		if f then
			local s = f:read("*a")
			f:close()
			if s and s:find("option enabled '1'") then enabled = "1" end
		end
	end
	os.execute("uci set sing-box.main.enabled='1' && uci commit sing-box && /etc/init.d/sing-box enable >/dev/null 2>&1")
	-- 先停，等旧进程彻底退出（最多 5 秒），再启动（INIT restart 是停＋启连发，
	-- 旧进程还没退出、新进程就去抢 TUN/端口，起不来；2026-11-22 导入实锤）
	-- （路由器 busybox 的 sleep 不支持小数，只能用整秒）
	os.execute("/etc/init.d/sing-box stop >/dev/null 2>&1")
	for _ = 1, 5 do
		if os.execute("pidof sing-box >/dev/null 2>&1") ~= 0 then break end
		os.execute("sleep 1")
	end
	os.execute("/etc/init.d/sing-box start >/dev/null 2>&1")
	-- 等新进程起来（最多 10 秒）；起不来补一次 start，再等 5 秒
	local ok = false
	for _ = 1, 10 do
		if os.execute("pidof sing-box >/dev/null 2>&1") == 0 then ok = true break end
		os.execute("sleep 1")
	end
	if not ok then os.execute("/etc/init.d/sing-box start >/dev/null 2>&1") end
	for _ = 1, 5 do
		if os.execute("pidof sing-box >/dev/null 2>&1") == 0 then ok = true break end
		os.execute("sleep 1")
	end
	if enabled ~= "1" then
		os.execute("uci set sing-box.main.enabled='0'; uci commit sing-box; /etc/init.d/sing-box disable >/dev/null 2>&1")
	end
	return ok
end
local rc = os.execute("pidof sing-box >/dev/null 2>&1")
if rc == 0 then
	if restart_preserve_autostart() then
		log("sing-box 已重启生效。")
	else
		log("sing-box 重启失败（进程未起来），请检查。")
	end
else
	log("sing-box 未运行，未重启。")
end
if logf then logf:close() end
