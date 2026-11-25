-- LuCI 控制器：sing-box 管理页（状态 / 节点 / 订阅 / 规则 / 高级 五页签）
-- 后端用 Lua + luci.jsonc；订阅解析、节点分组、规则编辑全在路由器本地完成。
-- config.json 只在用户保存且 sing-box check 通过后才原子替换。
-- 红线：DNS final=remote、102 排除（第一条）绝不动；warp-masque 出口仅在
-- 配置里存在时可用——固件 starter 不含它（无密钥），相关逻辑必须先判
-- 存在再引用（见 has_outbound / rebuild_outbounds / ensure_other_backup）。
-- VM 排除（192.168.2.100/32）与 Tailscale 排除（tailscale.com）是保隧道的默认规则，
-- 页面上标为“保护规则”，102 排除不可删、不可移位。
module("luci.controller.sing-box", package.seeall)

local _ = _ or function(s) return s end

local CONFFILE = "/etc/sing-box/config.json"
local NODESFILE = "/etc/sing-box/nodes.json"
local SUBSFILE = "/etc/sing-box/subscriptions.json"
local INIT = "/etc/init.d/sing-box"
local PROG = "/usr/bin/sing-box"
local TMPFILE = "/etc/sing-box/.config.json.tmp"
local CHECKOUT = "/tmp/sing-box-check.out"
local MAX_CONFIG = 524288  -- 512 KiB（新配置约 108KB）
local CLASH_API = "127.0.0.1:9090"
local LAT_CACHE = "/tmp/sing-box-latency.json"  -- 延迟缓存（异步刷新，页面不阻塞）
local SUB_CRON_SCRIPT = "/etc/sing-box/sub-refresh-cron.lua"  -- 订阅自动更新脚本（cron 调）
local SUB_CRON_LOG = "/tmp/sing-box-sub-refresh.log"  -- 自动更新日志
local SUB_CRON_LINE = "0 4 * * * lua " .. SUB_CRON_SCRIPT  -- 每天 04:00

local jsonc = require("luci.jsonc")

-- ---------- 通用 ----------
local function read_file(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local s = f:read("*a") or ""
	f:close()
	return s
end

local function write_file(path, content)
	local f = io.open(path, "w")
	if not f then return false end
	f:write(content)
	f:close()
	return true
end

local function read_json(path)
	local s = read_file(path)
	if not s or s == "" then return nil end
	local ok, v = pcall(jsonc.parse, s)
	if ok then return v end
	return nil
end

local function urldecode(s)
	if not s then return "" end
	s = s:gsub("+", " ")
	s = s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
	return s
end

-- ---------- 校验结果缓存 ----------
-- 页面打开不再同步跑全量 sing-box check（106K 配置、173 节点时该进程
-- VSZ 约 1.3G，在 AX6000 仅剩 20M 可用内存时卡死 D 状态；2026-11-24
-- 实锤）。校验结果改为缓存：每次保存/刷新/手动校验后写入，页面只读
-- 缓存显示；无缓存显示“未校验”。
local CHECK_CACHE = "/tmp/sing-box-check.cache"  -- 内容：ok|fail + 空格 + 时间
local function read_check_cache()
	local s = read_file(CHECK_CACHE)
	if not s or s == "" then return nil, nil end
	s = s:gsub("%s+$", "")
	local st, ts = s:match("^(%S+)%s+(.+)$")
	if st == "ok" then return true, ts end
	if st == "fail" then return false, ts end
	return nil, nil
end
local function write_check_cache(ok)
	write_file(CHECK_CACHE, (ok and "ok" or "fail") .. " " .. os.date("%Y-%m-%d %H:%M:%S"))
end

-- 配置里是否存在某出站（warp-masque 只在用户导入的配置里有；
-- 固件 starter 不含它，相关逻辑必须先判存在再引用）
local function has_outbound(cfg, tag)
	if not cfg or not cfg.outbounds then return false end
	for _, ob in ipairs(cfg.outbounds) do if ob.tag == tag then return true end end
	return false
end

-- ---------- 分流方案 A/B ----------
-- 国外流量规则（geosite geolocation-!cn）的出口决定当前方案：
-- warp-masque = 方案 A，other = 方案 B，direct = 直连（未走代理）；
-- 找不到规则返回 nil
local function foreign_rule_index(cfg)
	if not cfg or not cfg.route or not cfg.route.rules then return nil end
	for i, r in ipairs(cfg.route.rules) do
		-- 规则集写法（rule_set，如 geosite-geolocation-!cn）
		if r.rule_set == "geosite-geolocation-!cn" then return i end
		-- 内联写法（geosite 列表）
		if r.geosite then
			for _, g in ipairs(r.geosite) do
				if g == "geolocation-!cn" then return i end
			end
		end
	end
	return nil
end

local function current_scheme()
	local cfg = read_json(CONFFILE)
	if not cfg then return nil end
	local idx = foreign_rule_index(cfg)
	if not idx then return nil end
	local out = cfg.route.rules[idx].outbound or ""
	if out == "other" then return "b" end
	if out == "warp-masque" then return "a" end
	if out == "direct" then return "direct" end
	return nil
end

-- 分流方案自定义名称（存 UCI sing-box.main.scheme_a_name / scheme_b_name）
local function scheme_names()
	local uci = require("luci.model.uci").cursor()
	local a = uci:get("sing-box", "main", "scheme_a_name")
	local b = uci:get("sing-box", "main", "scheme_b_name")
	if not a or a == "" then a = "方案 A：国外走 warp" end
	if not b or b == "" then b = "方案 B：国外走订阅节点" end
	return a, b
end

-- 确保 other 组含 warp-masque（方案 B 的兜底）与 direct（最终兜底）；
-- 缺失时补上，返回是否改动。无 warp-masque 出口时不补它（starter
-- 配置不含密钥；缺了它往组里加只会造出引用不存在出口的非法配置，
-- 校验必失败）。direct 始终存在，始终补（v5：节点与 WARP 全死时
-- other 组也要能走直连，不黑洞）。
local function ensure_other_backup(cfg)
	local changed = false
	local has_warp = has_outbound(cfg, "warp-masque")
	for _, ob in ipairs(cfg.outbounds or {}) do
		if ob.tag == "other" and ob.type == "urltest" then
			ob.outbounds = ob.outbounds or {}
			local has_w, has_d = false, false
			for _, m in ipairs(ob.outbounds) do
				if m == "warp-masque" then has_w = true end
				if m == "direct" then has_d = true end
			end
			if has_warp and not has_w then
				table.insert(ob.outbounds, "warp-masque")
				changed = true
			end
			if not has_d then
				table.insert(ob.outbounds, "direct")
				changed = true
			end
		end
	end
	return changed
end

-- 订阅自动更新是否开启（crontab 里有无刷新行）
local function sub_auto_enabled()
	local sys = require("luci.sys")
	return sys.call("grep -q 'sub-refresh-cron' /etc/crontabs/root 2>/dev/null") == 0
end

-- 自动更新日志最后一行（无日志返回 ""）
local function sub_refresh_log_tail()
	local s = read_file(SUB_CRON_LOG)
	if not s or s == "" then return "" end
	s = s:gsub("%s+$", "")
	local last = s:match("([^\n]*)$") or ""
	return last
end

-- 校验并原子替换配置；返回 true/false, errmsg
local function save_config_checked(cfg_table)
	local text = jsonc.stringify(cfg_table, true)
	if not text or text == "" then return false, "生成配置失败（JSON 序列化为空）。" end
	if #text > MAX_CONFIG then return false, "配置过大（超过 512 KiB），未保存。" end
	if not write_file(TMPFILE, text) then return false, "无法写入临时文件，未保存。" end
	local sys = require("luci.sys")
	local mode = (sys.exec("stat -c %a " .. CONFFILE .. " 2>/dev/null") or ""):gsub("%s+$", "")
	if mode ~= "" then sys.call("chmod " .. mode .. " " .. TMPFILE .. " 2>/dev/null") end
	local rc = sys.call(PROG .. " check -c " .. TMPFILE .. " >" .. CHECKOUT .. " 2>&1")
	write_check_cache(rc == 0)
	if rc == 0 then
		sys.call("mv " .. TMPFILE .. " " .. CONFFILE)
		return true, nil
	end
	local out = read_file(CHECKOUT) or ""
	os.remove(TMPFILE)
	if #out > 2000 then out = out:sub(1, 2000) .. "……" end
	return false, "校验未通过，未写入。\n" .. out
end

-- ---------- 备份与恢复 ----------
-- 备份内容：config.json + subscriptions.json + nodes.json + UCI（方案名、自启）+ 订阅自动更新开关
-- 备份文件含 MASQUE 私钥与订阅凭证，导出后请妥善保管，勿外传。
local function build_backup()
	local uci = require("luci.model.uci").cursor()
	return {
		format = "sing-box-backup",
		version = 1,
		created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
		config = read_json(CONFFILE),
		subscriptions = read_json(SUBSFILE),
		nodes = read_json(NODESFILE),
		uci = {
			enabled = uci:get("sing-box", "main", "enabled") or "0",
			scheme_a_name = uci:get("sing-box", "main", "scheme_a_name"),
			scheme_b_name = uci:get("sing-box", "main", "scheme_b_name"),
		},
		sub_auto = sub_auto_enabled(),
	}
end

-- ---------- 状态 ----------
-- 取 sing-box 已运行时间（busybox ps 不支持 -o etime，改读 /proc；
-- /proc/<pid>/stat 第 22 字段是启动时刻（自开机起的时钟节拍，USER_HZ=100），
-- 与 /proc/uptime 的系统开机时长相减即进程运行时长）
local function proc_uptime(pid)
	local f = io.open("/proc/" .. pid .. "/stat", "r")
	if not f then return "" end
	local s = f:read("*a")
	f:close()
	local rest = s:match(".*%) (.*)$")
	if not rest then return "" end
	local fields = {}
	for w in rest:gmatch("%S+") do fields[#fields+1] = w end
	local starttime = tonumber(fields[20])
	if not starttime then return "" end
	local up = io.open("/proc/uptime", "r")
	if not up then return "" end
	local ups = up:read("*a")
	up:close()
	local sys_up = tonumber(ups:match("^(%S+)"))
	if not sys_up then return "" end
	local secs = math.floor(sys_up - starttime / 100)
	if secs < 0 then secs = 0 end
	local d = math.floor(secs / 86400)
	local h = math.floor(secs % 86400 / 3600)
	local m = math.floor(secs % 3600 / 60)
	local sec = secs % 60
	if d > 0 then return string.format("%d天%d小时%d分", d, h, m) end
	if h > 0 then return string.format("%d小时%d分", h, m) end
	if m > 0 then return string.format("%d分%d秒", m, sec) end
	return string.format("%d秒", sec)
end

local function get_state()
	local uci = require("luci.model.uci").cursor()
	local sys = require("luci.sys")
	local running = sys.call("pidof sing-box >/dev/null 2>&1") == 0
	local pid = ""
	local uptime = ""
	if running then
		pid = (sys.exec("pidof sing-box 2>/dev/null") or ""):gsub("%s+$", "")
		uptime = proc_uptime(pid)
	end
	local sb_version = (sys.exec(PROG .. " version 2>/dev/null") or ""):match("([^\n]*)") or ""
	local enabled = uci:get("sing-box", "main", "enabled") or "0"
	local user = uci:get("sing-box", "main", "user") or "root"
	local conffile = uci:get("sing-box", "main", "conffile") or CONFFILE
	local md5 = (sys.exec("md5sum " .. conffile .. " 2>/dev/null") or ""):match("^(%x+)") or ""
	local socks = sys.call("(ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep -q '127.0.0.1:1080'") == 0
	local tun0 = sys.call("ip link show tun0 >/dev/null 2>&1") == 0
	-- 校验状态只读缓存，不在页面加载时同步跑全量 check（会卡死设备，
	-- 见 CHECK_CACHE；手动校验见 action "check"）
	local check_ok, check_ts = read_check_cache()
	local config_text = read_file(conffile) or ""
	local cfg = read_json(conffile)
	local n_out = 0
	local n_rules = 0
	local default_out = ""
	if cfg then
		if cfg.outbounds then n_out = #cfg.outbounds end
		if cfg.route and cfg.route.rules then n_rules = #cfg.route.rules end
		if cfg.route then default_out = cfg.route.final or "" end
	end
	-- 延迟：只读缓存，不阻塞页面（Clash 式：后台异步刷新，见 refresh_latency）
	local lat_google, lat_yt = "", ""
	local lat_doc = read_json(LAT_CACHE)
	if lat_doc then
		lat_google = lat_doc.google or ""
		lat_yt = lat_doc.youtube or ""
	end
	local scheme_a_name, scheme_b_name = scheme_names()
	return {
		running = running, pid = pid, uptime = uptime, sb_version = sb_version,
		enabled = enabled, user = user, conffile = conffile, md5 = md5,
		socks = socks, tun0 = tun0, check_ok = check_ok, check_ts = check_ts,
		has_warp = has_outbound(cfg, "warp-masque"), config_text = config_text,
		n_out = n_out, n_rules = n_rules, default_out = default_out,
		lat_google = lat_google, lat_yt = lat_yt,
		scheme = current_scheme(), sub_auto = sub_auto_enabled(),
		sub_log = sub_refresh_log_tail(),
		scheme_a_name = scheme_a_name, scheme_b_name = scheme_b_name,
	}
end

-- 后台测延迟并写缓存（Clash 式异步：页面先出，数字随后填）
local function refresh_latency()
	local sys = require("luci.sys")
	local running = sys.call("pidof sing-box >/dev/null 2>&1") == 0
	local socks = false
	if running then
		socks = sys.call("(ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep -q '127.0.0.1:1080'") == 0
	end
	local lat_google, lat_yt = "", ""
	if running and socks then
		lat_google = (sys.exec("curl -o /dev/null -s -w '%{time_total}' --socks5-hostname 127.0.0.1:1080 --max-time 8 https://www.google.com/generate_204 2>/dev/null") or ""):gsub("%s+$", "")
		lat_yt = (sys.exec("curl -o /dev/null -s -w '%{time_total}' --socks5-hostname 127.0.0.1:1080 --max-time 8 https://www.youtube.com/ 2>/dev/null") or ""):gsub("%s+$", "")
	end
	local doc = { google = lat_google, youtube = lat_yt, ts = os.time() }
	write_file(LAT_CACHE, jsonc.stringify(doc))
	return doc
end

-- ---------- 节点 ----------
local function get_nodes()
	local doc = read_json(NODESFILE)
	if not doc then return nil end
	return doc
end

-- 节点 tag -> 订阅名（nodes.json 的 nodes[] 里有 sub 字段；节点名本身不可靠，
-- 如 fy 节点是订阅原始名 "🇲🇴 澳门｜MO 02"，不带 fy- 前缀，不能靠名字前缀判断订阅）
local function node_sub_map()
	local doc = read_json(NODESFILE)
	local m = {}
	if doc and doc.nodes then
		for _, n in ipairs(doc.nodes) do
			if n.tag and n.sub and n.sub ~= "" then m[n.tag] = n.sub end
		end
	end
	return m
end

-- TCP 连通时延（服务未运行时用，粗测到节点服务器的网络延迟）
local function tcp_latency(server, port)
	local sys = require("luci.sys")
	local out = sys.exec("sh -c 's=$(date +%s%N); nc -z -w 5 " .. server .. " " .. port .. " 2>/dev/null && e=$(date +%s%N) && echo $(( (e-s)/1000000 ))' 2>/dev/null") or ""
	out = out:gsub("%s+$", "")
	if out:match("^%d+$") then return tonumber(out) end
	return nil
end

-- clash_api 测速（服务运行时）：返回 {tag=ms}（urltest 组延迟）
local function clash_latency()
	local sys = require("luci.sys")
	local body = sys.exec("curl -s --max-time 5 http://" .. CLASH_API .. "/proxies 2>/dev/null") or ""
	if body == "" then return nil end
	local ok, doc = pcall(jsonc.parse, body)
	if not ok or not doc or not doc.proxies then return nil end
	local lat = {}
	for tag, p in pairs(doc.proxies) do
		if p.history and p.history[1] and p.history[1].delay then
			lat[tag] = p.history[1].delay
		end
	end
	return lat
end

-- 各 urltest 组当前选中的节点（Clash API /proxies 的 now 字段）
local function clash_groups()
	local sys = require("luci.sys")
	local body = sys.exec("curl -s --max-time 5 http://" .. CLASH_API .. "/proxies 2>/dev/null") or ""
	if body == "" then return nil end
	local ok, doc = pcall(jsonc.parse, body)
	if not ok or not doc or not doc.proxies then return nil end
	local groups = {}
	local names = { "us", "hk", "jp", "tw", "sg", "other" }
	local submap = node_sub_map()
	for _, name in ipairs(names) do
		local p = doc.proxies[name]
		if p then
			local delay = nil
			if p.history and p.history[1] and p.history[1].delay then
				delay = p.history[1].delay
			end
			groups[#groups + 1] = { name = name, now = p.now or "", delay = delay, sub = submap[p.now or ""] or "" }
		end
	end
	return groups
end

-- 实时连接（Clash API /connections）：每条连接的来源、目标与所走代理
local function clash_connections()
	local sys = require("luci.sys")
	local body = sys.exec("curl -s --max-time 5 http://" .. CLASH_API .. "/connections 2>/dev/null") or ""
	if body == "" then return nil end
	local ok, doc = pcall(jsonc.parse, body)
	if not ok or not doc or not doc.connections then return nil end
	local list = {}
	local submap = node_sub_map()
	local latmap = clash_latency() or {}
	for _, c in ipairs(doc.connections) do
		local m = c.metadata or {}
		local chains = c.chains or {}
		-- 订阅：取链路第一个出站（实际节点名）在 nodes.json 里的订阅归属；
		-- direct / warp-masque 不是订阅节点，订阅为空
		local sub = ""
		if chains[1] then sub = submap[chains[1]] or "" end
		-- 节点延迟：取链路第一个出站的 urltest 延迟（clash_api 的 history）；
		-- direct 无延迟数据，显示 —
		local lat = nil
		if chains[1] then lat = latmap[chains[1]] end
		list[#list + 1] = {
			src = (m.sourceIP or "") .. ":" .. tostring(m.sourcePort or ""),
			dst = (m.host ~= "" and m.host or m.destinationIP or "") .. ":" .. tostring(m.destinationPort or ""),
			proxy = table.concat(chains, " → "),
			sub = sub,
			lat = lat,
			down = c.download or 0,
			up = c.upload or 0,
		}
	end
	-- 按下载量倒序，最多 30 条
	table.sort(list, function(a, b) return (a.down + a.up) > (b.down + b.up) end)
	while #list > 30 do table.remove(list) end
	return list
end

-- ---------- 订阅 ----------
local function get_subs()
	local doc = read_json(SUBSFILE)
	if not doc or not doc.subscriptions then return {} end
	return doc.subscriptions
end

-- ---------- 规则 ----------
-- 保护规则：102 排除（第 1 条，不可删、不可移）、VM 排除、Tailscale 排除
local function is_protected_rule(rule)
	if not rule then return false end
	if rule.source_ip_cidr and rule.source_ip_cidr[1] == "192.168.2.4/32" then return true end
	if rule.source_ip_cidr and rule.source_ip_cidr[1] == "192.168.2.100/32" then return true end
	if rule.domain_suffix and #rule.domain_suffix == 1 and rule.domain_suffix[1] == "tailscale.com" then return true end
	return false
end

local function rule_label(rule)
	if not rule then return "" end
	if rule.source_ip_cidr then return "来源 " .. table.concat(rule.source_ip_cidr, ",") end
	if rule.domain_suffix then return "域名后缀 " .. table.concat(rule.domain_suffix, ",") end
	if rule.domain then return "域名 " .. table.concat(rule.domain, ",") end
	if rule.domain_keyword then return "域名关键词 " .. table.concat(rule.domain_keyword, ",") end
	if rule.port then return "端口 " .. tostring(rule.port) end
	if rule.geosite then return "geosite " .. table.concat(rule.geosite, ",") end
	if rule.geoip then return "geoip " .. table.concat(rule.geoip, ",") end
	if rule.rule_set then return "规则集 " .. tostring(rule.rule_set) end
	if rule.action == "sniff" then return "嗅探（sniff）" end
	if rule.inbound then return "入站 " .. tostring(rule.inbound) end
	return "(其他)"
end

function index()
	entry({"admin", "services", "sing-box"}, call("page"), _("sing-box"), 60).dependent = false
	entry({"admin", "services", "sing-box", "action"}, call("action"), nil).dependent = true
end

function page()
	local st = get_state()
	st.nodes = get_nodes()
	st.subs = get_subs()
	local cfg = read_json(CONFFILE)
	st.rules = (cfg and cfg.route and cfg.route.rules) or {}
	st.clash_lat = nil
	if st.running then st.clash_lat = clash_latency() end
	luci.template.render("sing-box/sing-box", st)
end

-- ---------- VLESS 解析与分组（订阅刷新用） ----------
local REGION_KEYWORDS = {
	us = {"美国", "🇺🇸", "US", "USA", "美西", "美东", "洛杉矶", "纽约", "旧金山", "西雅图", "芝加哥", "硅谷"},
	hk = {"香港", "🇭🇰", "HK", "Hong Kong"},
	jp = {"日本", "🇯🇵", "JP", "Japan", "东京", "大阪"},
	tw = {"台湾", "🇹🇼", "TW", "Taiwan", "台北"},
	sg = {"新加坡", "🇸🇬", "SG", "Singapore"},
}
local GROUP_LABEL = {us = "美国", hk = "香港", jp = "日本", tw = "台湾", sg = "新加坡", other = "其他"}
local EXCLUDE_WORDS = {"永久官网", "剩余流量", "套餐到期"}

local function group_of(name)
	for _, w in ipairs(EXCLUDE_WORDS) do
		if name:find(w, 1, true) then return nil end
	end
	for _, g in ipairs({"us", "hk", "jp", "tw", "sg"}) do
		for _, kw in ipairs(REGION_KEYWORDS[g]) do
			if name:find(kw, 1, true) then return g end
		end
	end
	return "other"
end

-- 解析一条 vless:// 链接；失败返回 nil
local function parse_vless(link)
	local uuid, server, port, query, name = link:match("^vless://([^@]+)@([^:]+):(%d+)%?([^#]*)#?(.*)$")
	if not uuid or not server or not port then return nil end
	name = urldecode(name or "")
	if name == "" then name = server .. ":" .. port end
	local params = {}
	for kv in (query or ""):gmatch("([^&]+)") do
		local k, v = kv:match("^([^=]+)=(.*)$")
		if k then params[k] = urldecode(v or "") end
	end
	local ob = {
		type = "vless", tag = name, server = server,
		server_port = tonumber(port), uuid = uuid,
	}
	if params.flow and params.flow ~= "" then ob.flow = params.flow end
	local sec = params.security or ""
	local sni = params.sni or params.servername or ""
	local fp = params.fingerprint or "chrome"
	if sec == "reality" then
		ob.tls = {
			enabled = true, server_name = sni,
			utls = {enabled = true, fingerprint = fp},
			reality = {
				enabled = true,
				public_key = params.pbk or "",
				short_id = params.sid or "",
			},
		}
	elseif sec == "tls" then
		ob.tls = {
			enabled = true, server_name = sni,
			utls = {enabled = true, fingerprint = fp},
		}
	end
	local t = params.type or "tcp"
	if t == "ws" then
		ob.transport = {
			type = "ws", path = params.path or "/",
			headers = {Host = params.host or server},
		}
	elseif t == "grpc" then
		ob.transport = {type = "grpc", service_name = params.serviceName or ""}
	end
	return ob
end

-- 从订阅文本（base64 或明文）解析出 outbound 列表
local function parse_subscription_text(text)
	local nodes = {}
	-- 若整段是 base64，先解码
	local decoded = text
	if not text:find("vless://", 1, true) then
		local sys = require("luci.sys")
		local tmp = "/tmp/sb-sub-decode.txt"
		-- 订阅 base64 常为几万字节的单行：本机 openssl base64 -d 的行缓冲装不下长单行，
		-- 整段解出 0 字节（64 字符短串可解、全量 59616 字节不可解，实测）。
		-- 先去空白、按 64 字符折行、补结尾换行再解。
		local b64 = text:gsub("%s+", "")
		local parts = {}
		for i = 1, #b64, 64 do parts[#parts + 1] = b64:sub(i, i + 63) end
		write_file(tmp, table.concat(parts, "\n") .. "\n")
		-- 主路由无 base64 小程序，优先用 openssl 解码（实测 base64 -d 不存在致解码为空）
		if sys.call("command -v openssl >/dev/null 2>&1") == 0 then
			sys.call("openssl base64 -d -in " .. tmp .. " > " .. tmp .. ".out 2>/dev/null")
		else
			sys.call("base64 -d " .. tmp .. " > " .. tmp .. ".out 2>/dev/null")
		end
		decoded = read_file(tmp .. ".out") or ""
		os.remove(tmp)
		os.remove(tmp .. ".out")
	end
	for line in (decoded or ""):gmatch("[^\r\n]+") do
		line = line:gsub("^%s+", ""):gsub("%s+$", "")
		if line:sub(1, 8) == "vless://" then
			local ob = parse_vless(line)
			if ob then nodes[#nodes + 1] = ob end
		end
	end
	return nodes
end

-- 用新节点集重建 outbounds（vless + 6 个 urltest 组）并写回 config；
-- 保留 warp-masque / direct / block 与 route.rules / dns / inbounds 原样。
-- 返回 true/false, errmsg, 统计
-- all_nodes 里的 outbound 可带 _sub（订阅名，仅用于 nodes.json，写配置前剥离）。
local function rebuild_outbounds(all_nodes)
	local cfg = read_json(CONFFILE)
	if not cfg then return false, "读取现有配置失败。", nil end
	local groups = {us = {}, hk = {}, jp = {}, tw = {}, sg = {}, other = {}}
	local kept = {}
	for _, ob in ipairs(all_nodes) do
		local g = group_of(ob.tag)
		if g then
			groups[g][#groups[g] + 1] = ob.tag
			kept[#kept + 1] = ob
		end
	end
	-- 去重 tag（同名节点加后缀）
	local seen = {}
	for _, ob in ipairs(kept) do
		local base = ob.tag
		local n = 1
		while seen[ob.tag] do
			n = n + 1
			ob.tag = base .. "-" .. n
		end
		seen[ob.tag] = true
	end
	-- 重新按去重后的 tag 建分组
	groups = {us = {}, hk = {}, jp = {}, tw = {}, sg = {}, other = {}}
	for _, ob in ipairs(kept) do
		local g = group_of(ob.tag)
		if g then groups[g][#groups[g] + 1] = ob.tag end
	end
	local new_out = {}
	for _, ob in ipairs(kept) do
		local clean = {}
		for k, v in pairs(ob) do
			if k ~= "_sub" then clean[k] = v end
		end
		new_out[#new_out + 1] = clean
	end
	-- warp-masque 兜底只在配置里真有该出口时加（starter 无密钥、无此出口；
	-- 无出口还往组里加会造出非法配置，校验必失败）
	local has_warp = has_outbound(cfg, "warp-masque")
	for _, g in ipairs({"us", "hk", "jp", "tw", "sg", "other"}) do
		if #groups[g] > 0 then
			-- us / other 组保留 warp-masque 兜底（订阅节点全挂时自动切 warp）
			local members = {}
			for _, t in ipairs(groups[g]) do members[#members + 1] = t end
			if (g == "us" or g == "other") and has_warp then members[#members + 1] = "warp-masque" end
			-- (v5) ultimate fallback: direct. Subscription nodes AND
			-- warp-masque both dead -> urltest falls back to direct so
			-- traffic still flows instead of black-holing (2026-11-25:
			-- nodes dead + WARP dead -> "other" gave 000 on
			-- Google/YouTube). "direct" always exists as an outbound.
			if g == "us" or g == "other" then members[#members + 1] = "direct" end
			new_out[#new_out + 1] = {
				type = "urltest", tag = g,
				outbounds = members,
				url = "http://cp.cloudflare.com/generate_204",
				interval = "3m", tolerance = 50,
			}
		end
	end
	-- 保留非 vless / 非 urltest 的原有出站（warp-masque / direct / block）
	local old = cfg.outbounds or {}
	for _, ob in ipairs(old) do
		if ob.type ~= "vless" and ob.type ~= "urltest" then
			new_out[#new_out + 1] = ob
		end
	end
	cfg.outbounds = new_out
	local ok, err = save_config_checked(cfg)
	if not ok then return false, err, nil end
	-- 更新 nodes.json（与沙箱 gen-config.py 同结构，供节点页用，不含凭证）
	local sub_count = {}
	for _, ob in ipairs(kept) do
		local s = ob._sub or ""
		sub_count[s] = (sub_count[s] or 0) + 1
	end
	local subs_list = {}
	for s, c in pairs(sub_count) do
		if s ~= "" then subs_list[#subs_list + 1] = {tag = s, node_count = c} end
	end
	table.sort(subs_list, function(a, b) return a.tag < b.tag end)
	local groups_list = {}
	for _, g in ipairs({"us", "hk", "jp", "tw", "sg", "other"}) do
		if #groups[g] > 0 then
			groups_list[#groups_list + 1] = {tag = g, name = GROUP_LABEL[g], node_count = #groups[g]}
		end
	end
	local nodes_list = {}
	for _, ob in ipairs(kept) do
		local g = group_of(ob.tag)
		local sec = ""
		if ob.tls and ob.tls.reality then sec = "reality"
		elseif ob.tls then sec = "tls" end
		nodes_list[#nodes_list + 1] = {
			tag = ob.tag, name = ob.tag, sub = ob._sub or "",
			region = g, region_name = GROUP_LABEL[g] or "其他",
			group = g, server = ob.server, port = ob.server_port,
			security = sec, transport = (ob.transport and ob.transport.type) or "tcp",
		}
	end
	local nodes_doc = {
		generated_at = os.date("%Y-%m-%d %H:%M"),
		subscriptions = subs_list,
		groups = groups_list,
		nodes = nodes_list,
	}
	write_file(NODESFILE, jsonc.stringify(nodes_doc, true))
	local stats = {total = #kept}
	for _, g in ipairs({"us", "hk", "jp", "tw", "sg", "other"}) do stats[g] = #groups[g] end
	return true, nil, stats
end

-- 拉取全部订阅并重建节点（手动刷新与 cron 自动更新共用）。
-- 返回 ok, errmsg, stats, failed, zero, preserved：
-- failed 为拉取失败的订阅名，zero 为拉取成功但解析出 0 个节点的订阅名，
-- preserved 为失败/0节点订阅保留的旧节点数（tag -> 数量）。
-- 失败/0节点的订阅保留其旧节点（订阅方临时故障不应清空节点，urltest 会自动跳过死节点）；
-- 全部失败或 0 节点时不改配置（保旧配置）。
function refresh_all_subscriptions()
	local sys = require("luci.sys")
	local subs = get_subs()
	if #subs == 0 then return false, "没有订阅可刷新。", nil, {}, {}, {} end
	-- 旧节点：按订阅归属（先查 nodes.json 的 tag->订阅映射，查不到再回落到名字前缀）
	local old_by_sub = {}
	local submap = node_sub_map()
	local old_cfg = read_json(CONFFILE)
	if old_cfg and old_cfg.outbounds then
		for _, ob in ipairs(old_cfg.outbounds) do
			if ob.type == "vless" and ob.tag then
				local stag = submap[ob.tag]
				if not stag then
					for _, s in ipairs(subs) do
						if ob.tag:sub(1, #s.tag + 1) == s.tag .. "-" then stag = s.tag end
					end
				end
				if stag then
					old_by_sub[stag] = old_by_sub[stag] or {}
					local copy = {}
					for k, v in pairs(ob) do copy[k] = v end
					copy._sub = stag
					old_by_sub[stag][#old_by_sub[stag] + 1] = copy
				end
			end
		end
	end
	local all_nodes = {}
	local failed = {}
	local function keep_old(tag)
		local kept = old_by_sub[tag] or {}
		for _, ob in ipairs(kept) do all_nodes[#all_nodes + 1] = ob end
		return #kept
	end
	local per_sub = {}
	local preserved = {}
	for _, s in ipairs(subs) do
		local tmp = "/tmp/sb-sub-fetch.txt"
		-- URL 用单引号包裹（内含单引号时转义），防 shell 元字符
		local qurl = "'" .. s.url:gsub("'", "'\\''") .. "'"
		local rc = sys.call("curl -s --max-time 30 -o " .. tmp .. " " .. qurl .. " 2>/dev/null")
		local text = read_file(tmp) or ""
		os.remove(tmp)
		if rc ~= 0 or text == "" then
			failed[#failed + 1] = s.tag
			local n = keep_old(s.tag)
			if n > 0 then preserved[s.tag] = n end
		else
			local nodes = parse_subscription_text(text)
			per_sub[s.tag] = #nodes
			if #nodes == 0 then
				local n = keep_old(s.tag)
				if n > 0 then preserved[s.tag] = n end
			else
				for _, ob in ipairs(nodes) do
					ob._sub = s.tag
					all_nodes[#all_nodes + 1] = ob
				end
			end
		end
	end
	if #all_nodes == 0 then
		local zero = {}
		for _, s in ipairs(subs) do
			if per_sub[s.tag] == 0 then zero[#zero + 1] = s.tag end
		end
		return false, "所有订阅拉取失败（" .. table.concat(failed, "、") .. "），配置未改动。", nil, failed, zero, preserved
	end
	local ok, err, stats = rebuild_outbounds(all_nodes)
	if not ok then return false, err, nil, failed, {}, preserved end
	local zero = {}
	for _, s in ipairs(subs) do
		if per_sub[s.tag] == 0 then zero[#zero + 1] = s.tag end
	end
	return true, nil, stats, failed, zero, preserved
end

-- ---------- 动作 ----------
-- 重启服务但保留开机自启设置：init 脚本的 start_service() 会在
-- sing-box.main.enabled=0 时直接返回 0 且不启动（restart 是先 stop 再
-- start，等于把服务停掉且不再起来）。所以重启前临时把 enabled 置 1，
-- 重启完再恢复原值；服务已在跑时改回 enabled 不影响当前进程。
-- （2026-11-22 实锤：用户关自启后切方案 A，restart 把服务停了且没起来，
-- 页面报“重启失败（init 脚本返回码 0）”——返回码 0 是 init 脚本“成功地
-- 什么都没做”。）
-- （2026-11-22 18:3x 再实锤：导入备份调本函数同样 rc=0 但服务没起来，
-- 用户只得手动点启动。根因：INIT restart 是停＋启连发，旧进程还没彻底
-- 退出、新进程就去抢 TUN/端口，起不来；且 init 返回码 0 不代表进程在跑。
-- 修法：改显式 stop→等旧进程死透→start，并轮询确认进程真的在跑，
-- 起不来补一次 start；返回值以进程是否在跑为准，不再信 init 返回码。）
local function restart_preserve_autostart()
	local sys = require("luci.sys")
	local enabled = (sys.exec("uci get sing-box.main.enabled 2>/dev/null") or ""):gsub("%s+$", "")
	-- 临时开自启（start_service 在 enabled=0 时直接 return 0 不启动）
	sys.call("uci set sing-box.main.enabled='1' && uci commit sing-box && " .. INIT .. " enable")
	-- 先停，等旧进程彻底退出（最多 5 秒），再启动
	-- （路由器 busybox 的 sleep 不支持小数，只能用整秒）
	sys.call(INIT .. " stop")
	for _ = 1, 5 do
		if sys.call("pidof sing-box >/dev/null 2>&1") ~= 0 then break end
		sys.call("sleep 1")
	end
	sys.call(INIT .. " start")
	-- 等新进程起来（最多 10 秒）；起不来补一次 start，再等 5 秒
	local ok = false
	for _ = 1, 10 do
		if sys.call("pidof sing-box >/dev/null 2>&1") == 0 then ok = true break end
		sys.call("sleep 1")
	end
	if not ok then sys.call(INIT .. " start") end
	for _ = 1, 5 do
		if sys.call("pidof sing-box >/dev/null 2>&1") == 0 then ok = true break end
		sys.call("sleep 1")
	end
	-- 恢复原自启值
	if enabled ~= "1" then
		sys.call("uci set sing-box.main.enabled='0'; uci commit sing-box; " .. INIT .. " disable")
	end
	return ok and 0 or 1
end

function action()
	local http = require("luci.http")
	local sys = require("luci.sys")
	-- 备份导入：只在 multipart 文件上传时才注册文件处理器；
	-- 普通表单（URL-encoded）不注册，避免干扰 formvalue 解析
	local upload_data = ""
	local upload_err = nil
	local ct = http.getenv("CONTENT_TYPE") or ""
	if ct:find("multipart/form-data", 1, true) then
		http.setfilehandler(function(meta, chunk, eof)
			if upload_err then return end
			if not chunk then return end
			upload_data = upload_data .. chunk
			if #upload_data > 1048576 then
				upload_err = "备份文件过大（超过 1 MiB），未导入。"
			end
		end)
	end
	local act = http.formvalue("action") or ""
	local st = get_state()

	if act == "start" then
		local rc = sys.call("uci set sing-box.main.enabled='1' && uci commit sing-box && " .. INIT .. " enable && " .. INIT .. " start")
		sys.call("sleep 3")
		st = get_state()
		if st.running then st.message = "sing-box 已启动。"
		else st.errmsg = "启动失败（init 脚本返回码 " .. tostring(rc) .. "），请看下方状态，或用 SSH 看日志。" end
	elseif act == "stop" then
		sys.call(INIT .. " stop; uci set sing-box.main.enabled='0'; uci commit sing-box; " .. INIT .. " disable")
		sys.call("sleep 3")
		st = get_state()
		if not st.running then st.message = "sing-box 已停止（开机自启已关闭）。"
		else st.errmsg = "停止失败，进程仍在，请用 SSH 检查。" end
	elseif act == "restart" then
		-- 重启只应用当前配置，不改开机自启设置（用保留自启的重启）
		local rc = restart_preserve_autostart()
		sys.call("sleep 3")
		st = get_state()
		if st.running then st.message = "sing-box 已重启。"
		else st.errmsg = "重启失败（init 脚本返回码 " .. tostring(rc) .. "），请看下方状态，或用 SSH 看日志。" end
	elseif act == "autostart" then
		local want = http.formvalue("enabled") == "1"
		if want then
			sys.call("uci set sing-box.main.enabled='1'; uci commit sing-box; " .. INIT .. " enable")
		else
			sys.call("uci set sing-box.main.enabled='0'; uci commit sing-box; " .. INIT .. " disable")
		end
		st = get_state()
		if want then st.message = "开机自启已开启（服务未启动时仍需点“启动”才会立即运行）。"
		else st.message = "开机自启已关闭。" end
	elseif act == "latency" then
		-- 异步测延迟：返回 JSON，页面用 AJAX 刷新数字，不阻塞渲染
		local doc = refresh_latency()
		http.prepare_content("application/json")
		http.write_json(doc)
		return
	elseif act == "traffic" then
		-- 当前选中节点 + 实时连接：返回 JSON，页面用 AJAX 刷新
		local doc = { groups = clash_groups() or {}, connections = clash_connections() or {} }
		http.prepare_content("application/json")
		http.write_json(doc)
		return
	elseif act == "check" then
		-- 手动校验（按需触发）：页面打开不再自动跑全量 check，点“立即校验”才跑
		local rc = sys.call(PROG .. " check -c " .. CONFFILE .. " >" .. CHECKOUT .. " 2>&1")
		write_check_cache(rc == 0)
		st = get_state()
		if rc == 0 then st.message = "配置校验通过。"
		else
			local out = read_file(CHECKOUT) or ""
			if #out > 2000 then out = out:sub(1, 2000) .. "……" end
			st.errmsg = "配置校验未通过。"
			st.check_output = out
		end
	elseif act == "save_config" then
		local content = http.formvalue("config") or ""
		if content == "" then
			st.errmsg = "配置为空，未保存。"
		elseif #content > MAX_CONFIG then
			st.errmsg = "配置过大（超过 512 KiB），未保存。"
		else
			if not write_file(TMPFILE, content) then
				st.errmsg = "无法写入临时文件，未保存。"
			else
				local mode = (sys.exec("stat -c %a " .. CONFFILE .. " 2>/dev/null") or ""):gsub("%s+$", "")
				if mode ~= "" then sys.call("chmod " .. mode .. " " .. TMPFILE .. " 2>/dev/null") end
				local rc = sys.call(PROG .. " check -c " .. TMPFILE .. " >" .. CHECKOUT .. " 2>&1")
				write_check_cache(rc == 0)
				if rc == 0 then
					sys.call("mv " .. TMPFILE .. " " .. CONFFILE)
					st = get_state()
					st.message = "配置已保存并通过校验。"
				else
					local out = read_file(CHECKOUT) or ""
					os.remove(TMPFILE)
					if #out > 2000 then out = out:sub(1, 2000) .. "……" end
					st.errmsg = "校验未通过，未写入。"
					st.check_output = out
				end
			end
		end
	elseif act == "backup_export" then
		-- 导出备份：把当前配置、订阅、节点、方案名、自启与自动更新开关打成一个 JSON 文件下载
		local backup = build_backup()
		if not backup.config then
			st.errmsg = "读取配置失败，无法导出备份。"
		else
			local s = jsonc.stringify(backup, true)
			local fn = "sing-box-backup-" .. os.date("%Y%m%d-%H%M%S") .. ".json"
			http.header("Content-Disposition", "attachment; filename=\"" .. fn .. "\"")
			http.prepare_content("application/json")
			http.write(s)
			return
		end
	elseif act == "backup_import" then
		-- 导入备份：先校验备份里的配置，通过才写入并重启；通不过原样不动
		if upload_err then
			st.errmsg = upload_err
		elseif upload_data == "" then
			st.errmsg = "未收到备份文件，请先选择文件再点“导入备份”。"
		else
			local ok, backup = pcall(jsonc.parse, upload_data)
			if not ok or type(backup) ~= "table" then
				st.errmsg = "备份文件不是有效的 JSON，未导入。"
			elseif backup.format ~= "sing-box-backup" then
				st.errmsg = "这不是 sing-box 备份文件（缺少格式标记），未导入。"
			elseif type(backup.config) ~= "table" then
				st.errmsg = "备份文件里没有配置内容，未导入。"
			else
				local ok2, err2 = save_config_checked(backup.config)
				if not ok2 then
					st.errmsg = "备份里的配置校验未通过，未导入：" .. (err2 or "")
				else
					-- 写订阅与节点（有才写，缺了就跳过）
					if type(backup.subscriptions) == "table" then
						if write_file(SUBSFILE, jsonc.stringify(backup.subscriptions, true)) then
							sys.call("chmod 600 " .. SUBSFILE .. " 2>/dev/null")
						end
					end
					if type(backup.nodes) == "table" then
						write_file(NODESFILE, jsonc.stringify(backup.nodes, true))
					end
					-- 恢复 UCI（方案名、自启）
					if type(backup.uci) == "table" then
						local uci = require("luci.model.uci").cursor()
						if backup.uci.enabled == "1" or backup.uci.enabled == "0" then
							uci:set("sing-box", "main", "enabled", backup.uci.enabled)
						end
						if backup.uci.scheme_a_name and backup.uci.scheme_a_name ~= "" then
							uci:set("sing-box", "main", "scheme_a_name", backup.uci.scheme_a_name)
						end
						if backup.uci.scheme_b_name and backup.uci.scheme_b_name ~= "" then
							uci:set("sing-box", "main", "scheme_b_name", backup.uci.scheme_b_name)
						end
						uci:commit("sing-box")
						if backup.uci.enabled == "1" then sys.call(INIT .. " enable") else sys.call(INIT .. " disable") end
					end
					-- 恢复订阅自动更新开关
					if backup.sub_auto ~= nil then
						local crontab = "/etc/crontabs/root"
						local lines = {}
						local cur = read_file(crontab) or ""
						for line in (cur .. "\n"):gmatch("([^\n]*)\n") do
							if not line:find("sub-refresh-cron", 1, true) then
								if line ~= "" then lines[#lines + 1] = line end
							end
						end
						if backup.sub_auto then lines[#lines + 1] = SUB_CRON_LINE end
						if write_file(crontab, table.concat(lines, "\n") .. "\n") then
							sys.call("/etc/init.d/cron restart 2>/dev/null; /etc/init.d/cron reload 2>/dev/null")
						end
					end
					-- 重启服务（保留自启）
					local rc = restart_preserve_autostart()
					sys.call("sleep 3")
					st = get_state()
					if st.running then
						st.message = "备份已导入并通过校验，服务已重启。"
					else
						st.errmsg = "备份已导入但重启失败（init 脚本返回码 " .. tostring(rc) .. "），请用 SSH 检查。"
					end
				end
			end
		end
	elseif act == "sub_add" then
		local tag = (http.formvalue("tag") or ""):gsub("^%s+", ""):gsub("%s+$", "")
		local url = (http.formvalue("url") or ""):gsub("^%s+", ""):gsub("%s+$", "")
		if tag == "" or url == "" then
			st.errmsg = "订阅名与 URL 都不能为空，未添加。"
		else
			local subs = get_subs()
			local dup = false
			for _, s in ipairs(subs) do if s.tag == tag then dup = true end end
			if dup then
				st.errmsg = "已存在同名订阅“" .. tag .. "”，未添加。"
			else
				subs[#subs + 1] = {tag = tag, url = url}
				if write_file(SUBSFILE, jsonc.stringify({subscriptions = subs}, true)) then
					sys.call("chmod 600 " .. SUBSFILE .. " 2>/dev/null")
					st.message = "订阅“" .. tag .. "”已添加（未拉取，请点“刷新”导入节点）。"
				else
					st.errmsg = "写入订阅文件失败。"
				end
			end
		end
	elseif act == "sub_del" then
		local tag = http.formvalue("tag") or ""
		local subs = get_subs()
		local kept_subs = {}
		for _, s in ipairs(subs) do if s.tag ~= tag then kept_subs[#kept_subs + 1] = s end end
		if #kept_subs == #subs then
			st.errmsg = "未找到订阅“" .. tag .. "”。"
		elseif write_file(SUBSFILE, jsonc.stringify({subscriptions = kept_subs}, true)) then
			sys.call("chmod 600 " .. SUBSFILE .. " 2>/dev/null")
			st.message = "订阅“" .. tag .. "”已删除（节点仍在配置里，如需清除请刷新其余订阅或手动编辑）。"
		else
			st.errmsg = "写入订阅文件失败。"
		end
	elseif act == "sub_refresh" then
		local ok, err, stats, failed, zero, preserved = refresh_all_subscriptions()
		if not ok then
			st.errmsg = err or "刷新失败。"
			if zero and #zero > 0 then
				st.errmsg = st.errmsg .. "（以下订阅拉取成功但解析出 0 节点：" .. table.concat(zero, "、") .. "）"
			end
		else
			local msg = "刷新完成：共 " .. tostring(stats.total) .. " 个节点（"
			local parts = {}
			for _, g in ipairs({"us", "hk", "jp", "tw", "sg", "other"}) do
				if stats[g] and stats[g] > 0 then parts[#parts + 1] = GROUP_LABEL[g] .. " " .. stats[g] end
			end
			msg = msg .. table.concat(parts, "、") .. "）。"
			if #failed > 0 then msg = msg .. "失败订阅：" .. table.concat(failed, "、") .. "（其节点未更新）。" end
			if zero and #zero > 0 then msg = msg .. "0 节点订阅：" .. table.concat(zero, "、") .. "（拉取成功但无节点，疑似订阅失效）。" end
			if preserved then
				local pp = {}
				for tag, n in pairs(preserved) do pp[#pp + 1] = tag .. " " .. n .. " 个旧节点" end
				if #pp > 0 then msg = msg .. "已保留：" .. table.concat(pp, "、") .. "。" end
			end
			msg = msg .. "配置已校验通过并保存；服务正在运行时请点“重启”生效。"
			st.message = msg
		end
	elseif act == "sub_test" then
		-- 测通单个订阅：拉取一次并数节点，只测不保存
		local tag = http.formvalue("tag") or ""
		local subs = get_subs()
		local url = nil
		for _, s in ipairs(subs) do if s.tag == tag then url = s.url end end
		if not url then
			st.errmsg = "未找到订阅“" .. tag .. "”。"
		else
			local tmp = "/tmp/sb-sub-test.txt"
			local codefile = "/tmp/sb-sub-test.code"
			local qurl = "'" .. url:gsub("'", "'\\''") .. "'"
			local t0 = os.time()
			local rc = sys.call("curl -s --max-time 15 -o " .. tmp .. " -w '%{http_code}' " .. qurl .. " 2>/dev/null > " .. codefile)
			local code = (read_file(codefile) or ""):gsub("%s+$", "")
			local text = read_file(tmp) or ""
			local dt = os.time() - t0
			os.remove(tmp)
			os.remove(codefile)
			if rc ~= 0 or text == "" then
				st.errmsg = "订阅“" .. tag .. "”测通失败（HTTP " .. (code ~= "" and code or "无响应") .. "，耗时 " .. dt .. " 秒），请检查订阅 URL 是否过期。"
			else
				local nodes = parse_subscription_text(text)
				st.message = "订阅“" .. tag .. "”测通成功：HTTP " .. code .. "，耗时 " .. dt .. " 秒，可解析 " .. #nodes .. " 个节点（未保存，仅测试）。"
			end
		end
	elseif act == "sub_autorefresh" then
		-- 订阅自动更新开关：每天 04:00 跑 cron 刷新
		local want = http.formvalue("enabled") == "1"
		local crontab = "/etc/crontabs/root"
		local lines = {}
		local cur = read_file(crontab) or ""
		for line in (cur .. "\n"):gmatch("([^\n]*)\n") do
			if not line:find("sub-refresh-cron", 1, true) then
				if line ~= "" then lines[#lines + 1] = line end
			end
		end
		if want then lines[#lines + 1] = SUB_CRON_LINE end
		if write_file(crontab, table.concat(lines, "\n") .. "\n") then
			sys.call("/etc/init.d/cron restart 2>/dev/null; /etc/init.d/cron reload 2>/dev/null")
			st = get_state()
			if want then st.message = "订阅自动更新已开启：每天 04:00 自动刷新（失败或 0 节点时不更新，成功后自动重启生效）。"
			else st.message = "订阅自动更新已关闭。" end
		else
			st.errmsg = "写入 crontab 失败，开关未改动。"
		end
	elseif act == "scheme" then
		-- 分流方案切换：只改国外流量规则（geolocation-!cn）的出口
		-- A = warp-masque，B = other（订阅节点，warp-masque 兜底）
		local want = http.formvalue("name") or ""
		local cfg = read_json(CONFFILE)
		if not cfg then
			st.errmsg = "读取配置失败。"
		else
			local idx = foreign_rule_index(cfg)
			if not idx then
				st.errmsg = "未找到国外流量规则（geolocation-!cn），无法切换。"
			elseif want ~= "b" and not has_outbound(cfg, "warp-masque") then
				st.errmsg = "本机未配置 warp-masque（固件 starter 不含密钥），无法切换到方案 A；请先添加订阅并用方案 B。"
			else
				local target = (want == "b") and "other" or "warp-masque"
				cfg.route.rules[idx].outbound = target
				ensure_other_backup(cfg)
				local ok, err = save_config_checked(cfg)
				if not ok then
					st.errmsg = "切换失败：" .. (err or "")
				else
					-- 切换方案只改规则出口，不改开机自启设置（用保留自启的重启）
					local rc = restart_preserve_autostart()
					sys.call("sleep 3")
					st = get_state()
					if st.running then
						local an, bn = scheme_names()
						-- 切换只改配置并重启；重启后各组需重新测速才能选出最快节点，
						-- 所以 UI 显示已切换时实际路由可能还要 1–3 分钟才完全生效
						if want == "b" then st.message = "已切换到“" .. bn .. "”：国外流量走订阅节点（other 组），warp-masque 兜底。正在测速，约 1–3 分钟后完全生效。"
						else st.message = "已切换到“" .. an .. "”：国外流量走 warp-masque。正在测速，约 1–3 分钟后完全生效。" end
					else
						st.errmsg = "配置已保存但重启失败（init 脚本返回码 " .. tostring(rc) .. "），请用 SSH 检查。"
					end
				end
			end
		end
	elseif act == "scheme_rename" then
		-- 分流方案改名：只改显示名，不动规则与出口
		local a = (http.formvalue("scheme_a_name") or ""):gsub("^%s+", ""):gsub("%s+$", "")
		local b = (http.formvalue("scheme_b_name") or ""):gsub("^%s+", ""):gsub("%s+$", "")
		if a == "" and b == "" then
			st.errmsg = "两个名字都为空，未改动。"
		else
			local sys2 = require("luci.sys")
			local cmds = {}
			if a ~= "" then cmds[#cmds + 1] = "uci set sing-box.main.scheme_a_name='" .. a:gsub("'", "'\\''") .. "'" end
			if b ~= "" then cmds[#cmds + 1] = "uci set sing-box.main.scheme_b_name='" .. b:gsub("'", "'\\''") .. "'" end
			cmds[#cmds + 1] = "uci commit sing-box"
			sys2.call(table.concat(cmds, "; ") .. " 2>/dev/null")
			st = get_state()
			st.message = "方案名称已保存。"
		end
	elseif act == "rule_add" then
		local kind = http.formvalue("kind") or "domain_suffix"
		local value = (http.formvalue("value") or ""):gsub("^%s+", ""):gsub("%s+$", "")
		local outbound = http.formvalue("outbound") or "direct"
		if value == "" then
			st.errmsg = "匹配值不能为空，未添加。"
		else
			local cfg = read_json(CONFFILE)
			if not cfg then
				st.errmsg = "读取配置失败。"
			elseif outbound ~= "direct" and outbound ~= "block" and not has_outbound(cfg, outbound) then
				st.errmsg = "出口“" .. outbound .. "”不存在（请先添加对应节点/出口，或选 direct）。"
			else
				local rule = {outbound = outbound}
				if kind == "domain_suffix" then
					local list = {}
					for d in value:gmatch("[^,%s]+") do list[#list + 1] = d end
					rule.domain_suffix = list
				elseif kind == "domain_keyword" then
					local list = {}
					for d in value:gmatch("[^,%s]+") do list[#list + 1] = d end
					rule.domain_keyword = list
				elseif kind == "source_ip_cidr" then
					rule.source_ip_cidr = {value}
				elseif kind == "port" then
					rule.port = tonumber(value) or value
				elseif kind == "geosite" then
					rule.geosite = {value}
				elseif kind == "geoip" then
					rule.geoip = {value}
				elseif kind == "ip_cidr" then
					rule.ip_cidr = {value}
				else
					st.errmsg = "未知匹配类型。"
					rule = nil
				end
				if rule then
					cfg.route = cfg.route or {}
					cfg.route.rules = cfg.route.rules or {}
					-- 新规则插在 final 代理规则之前、国内直连规则之后（即倒数第 3 条之前）；
					-- 简单起见插到最后一条（geosite-geolocation-!cn）之前
					local rules = cfg.route.rules
					local pos = #rules
					if pos >= 1 then
						table.insert(rules, pos, rule)
					else
						rules[#rules + 1] = rule
					end
					local ok, err = save_config_checked(cfg)
					if ok then st.message = "规则已添加并通过校验。"
					else st.errmsg = "添加规则失败：" .. (err or "") end
				end
			end
		end
	elseif act == "rule_del" then
		local idx = tonumber(http.formvalue("idx") or "")
		local cfg = read_json(CONFFILE)
		if not cfg or not cfg.route or not cfg.route.rules then
			st.errmsg = "读取配置失败。"
		elseif not idx or idx < 1 or idx > #cfg.route.rules then
			st.errmsg = "规则序号无效。"
		elseif is_protected_rule(cfg.route.rules[idx]) then
			st.errmsg = "这是保护规则（102 / VM / Tailscale 排除），不可删除。"
		else
			table.remove(cfg.route.rules, idx)
			local ok, err = save_config_checked(cfg)
			if ok then st.message = "规则已删除并通过校验。"
			else st.errmsg = "删除规则失败：" .. (err or "") end
		end
	elseif act == "rule_move" then
		local idx = tonumber(http.formvalue("idx") or "")
		local dir = http.formvalue("dir") or "up"
		local cfg = read_json(CONFFILE)
		if not cfg or not cfg.route or not cfg.route.rules then
			st.errmsg = "读取配置失败。"
		elseif not idx or idx < 1 or idx > #cfg.route.rules then
			st.errmsg = "规则序号无效。"
		elseif idx == 1 and dir == "up" then
			st.errmsg = "已是第一条，无法上移（102 排除必须保持第一）。"
		elseif is_protected_rule(cfg.route.rules[idx]) and idx == 1 then
			st.errmsg = "第一条是 102 排除保护规则，不可移动。"
		else
			local rules = cfg.route.rules
			local j = (dir == "up") and (idx - 1) or (idx + 1)
			if j < 1 or j > #rules then
				st.errmsg = "无法移动（已到边界）。"
			elseif is_protected_rule(rules[j]) and j == 1 then
				st.errmsg = "不能移到 102 排除规则之前。"
			else
				rules[idx], rules[j] = rules[j], rules[idx]
				local ok, err = save_config_checked(cfg)
				if ok then st.message = "规则顺序已调整并通过校验。"
				else st.errmsg = "调整顺序失败：" .. (err or "") end
			end
		end
	else
		st.errmsg = "未知操作。"
	end

	st.nodes = get_nodes()
	st.subs = get_subs()
	local cfg = read_json(CONFFILE)
	st.rules = (cfg and cfg.route and cfg.route.rules) or {}
	st.clash_lat = nil
	if st.running then st.clash_lat = clash_latency() end
	luci.template.render("sing-box/sing-box", st)
end
