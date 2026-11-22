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
	local f = io.popen("uci get sing-box.main.enabled 2>/dev/null")
	local enabled = f and f:read("*a") or ""
	if f then f:close() end
	enabled = enabled:gsub("%s+$", "")
	os.execute("uci set sing-box.main.enabled='1' && uci commit sing-box && /etc/init.d/sing-box enable && /etc/init.d/sing-box restart >/dev/null 2>&1")
	if enabled ~= "1" then
		os.execute("uci set sing-box.main.enabled='0'; uci commit sing-box; /etc/init.d/sing-box disable >/dev/null 2>&1")
	end
end
local rc = os.execute("pidof sing-box >/dev/null 2>&1")
if rc == 0 then
	restart_preserve_autostart()
	log("sing-box 已重启生效。")
else
	log("sing-box 未运行，未重启。")
end
if logf then logf:close() end
