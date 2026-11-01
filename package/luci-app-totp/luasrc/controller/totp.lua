-- LuCI 控制器：TOTP 二次验证（实验版）
-- 注意：本控制器只提供设置页与验证码页。登录流程的真正接管由
-- totp-patch-login.sh 完成（见 README“接管说明”）；未打补丁时，
-- 设置页会明确显示“登录流程未接管，验证器暂不生效”，不谎称已保护。
--
-- 设置页（admin/services/totp）为控制器直出模板（totp/setup），不再走 CBI：
-- 主界面只留密钥 + 二维码 + 验证码 + 启用开关；SSH 同步、内网放行、
-- 受信段、规则与状态收进“高级”。绑定流程：扫码 → 输一次 6 位码验证通过
-- 才算绑定完成，未绑定时启用请求会被拒绝（不再是先启用、后绑定的顺序）。
module("luci.controller.totp", package.seeall)

-- 与旧 CBI 页同理：新版 LuCI（ucode 桥）可能不提供全局 _，缺失时退回原串。
local _ = _ or function(s) return s end

local BOUND_FILE = "/etc/totp/bound"
local ONCE_FILE = "/tmp/totp-recovery-once"

local function bound_exists()
	local f = io.open(BOUND_FILE, "r")
	if f then f:close() return true end
	return false
end

local function set_bound(on)
	if on then
		local f = io.open(BOUND_FILE, "w")
		if f then f:write("1\n") f:close() end
		os.execute("chmod 600 " .. BOUND_FILE .. " 2>/dev/null")
	else
		os.remove(BOUND_FILE)
	end
end

-- 补丁状态判定（铁律：标记与钩子缺一不可，缺一律不显示“已打”）：
--   标记 = /etc/totp/patch-applied（补丁脚本仅在功能性钩子实测在位后才写）
--   钩子 = /usr/share/ucode/luci/dispatcher.uc 里含 luci-totp-gate-v1 锚串
-- 不一致时 patch_mismatch 为真，页面显示异常警告、绝不显示“已打”。
local DISPATCHER_UC = "/usr/share/ucode/luci/dispatcher.uc"
local HOOK_ANCHOR = "luci-totp-gate-v1"

local function patch_status(sys)
	local marker = sys.exec("test -f /etc/totp/patch-applied && echo yes || echo no"):gsub("%s+", "") == "yes"
	local hook = sys.exec("grep -q '" .. HOOK_ANCHOR .. "' " .. DISPATCHER_UC .. " 2>/dev/null && echo yes || echo no"):gsub("%s+", "") == "yes"
	local info = ""
	if marker then
		info = sys.exec("cat /etc/totp/patch-applied 2>/dev/null"):gsub("%s+$", "")
	end
	return {
		applied = marker and hook,
		mismatch = marker ~= hook,
		info = info,
	}
end

-- 设置页状态（只读展示，绝不把备用码明文带进状态）。
local function setup_state()
	local uci = require("luci.model.uci").cursor()
	local sys = require("luci.sys")
	local totp = require("luci.totp")
	local secret = totp.get_secret()
	local networks = uci:get_list("totp", "main", "lan_networks") or {}
	local ps = patch_status(sys)
	return {
		secret = secret,
		uri = secret and totp.otpauth_uri(secret, "root", "OpenWrt") or nil,
		bound = bound_exists(),
		enabled = uci:get("totp", "main", "enabled") or "0",
		ssh_sync = uci:get("totp", "main", "ssh_sync") or "0",
		lan_bypass = uci:get("totp", "main", "lan_bypass") or "1",
		lan_networks_text = table.concat(networks, "\n"),
		patch_applied = ps.applied,
		patch_mismatch = ps.mismatch,
		patch_info = ps.info,
		ga_exists = sys.exec("test -f /root/.google_authenticator && echo yes || echo no"):gsub("%s+", "") == "yes",
		time_now = os.date("!%Y-%m-%d %H:%M UTC"),
	}
end

function index()
	entry({"admin", "services", "totp"}, call("setup"), _("TOTP 二次验证"), 60).dependent = false
	entry({"admin", "services", "totp", "setup_post"}, call("setup_post"), nil).dependent = true
	-- 公开第二步验证节点（顶层 totp/verify_login，不在 admin 树下）：
	-- 顶层节点没有 auth 祖先，dispatcher 的认证块天然跳过（不依赖
	-- 空 auth 对象经 Lua 桥转换的语义）；未登录用户凭 totp_pending
	-- cookie + 表单 token 双绑定进入，绝不认完整会话、绝不认 URL token。
	entry({"totp", "verify_login"}, call("verify_login"), nil, 62).dependent = false
end

-- 设置页：完整 LuCI 会话内渲染（管理员已登录），只做配置，不做登录接管。
function setup()
	luci.template.render("totp/setup", setup_state())
end

-- 以管理员会话运行补丁脚本并回显输出（仅 setup_post 内调用）。
-- 成功定义为脚本退出码 0；输出原样回显，状态行按脚本跑完后的
-- patch_status 重读，绝不只凭 marker 或脚本输出断言“已打”。
local function run_patch(action)
	local f = io.popen("/usr/sbin/totp-patch-login.sh " .. action .. " 2>&1")
	if not f then return false, "" end
	local out = f:read("*a") or ""
	local ok = f:close()
	return (ok == true or ok == 0), out
end

-- 设置页表单提交：regen / verify / enable / recovery / advanced / patch_toggle。
-- 本函数只在完整 LuCI 会话内可达（admin/* 树由 dispatcher 要求登录），
-- 与旧 CBI 页的安全姿态一致；验证码校验复用核心 verify_code（含 ±1 步
-- 容差、防重放与限流），绑定验证成功会消耗当步计数器（可接受）。
-- enable 保存时自动打/恢复补丁、patch_toggle 手动打/恢复：钩子已由
-- 真机（qemu OpenWrt 25.12）端到端验证，页面按钮才允许接线于此；
-- 失败时状态行按实测重读、另给 errmsg，绝不显示未证实的“已打”。
function setup_post()
	local http = require("luci.http")
	local uci = require("luci.model.uci").cursor()
	local totp = require("luci.totp")
	local action = http.formvalue("action") or ""
	local st = setup_state()

	if action == "regen" then
		local secret = totp.generate_secret()
		totp.set_secret(secret)
		-- 换密钥即作废旧备用码与旧绑定：旧码哈希与防重放计数一并清除。
		os.execute("rm -f /etc/totp/recovery.sha1 /etc/totp/last-counter 2>/dev/null")
		set_bound(false)
		-- 换密钥后若仍开着启用，旧验证器立刻失效会把自己锁在外面：
		-- 启用自动关闭，须重新验证后再开启。
		if st.enabled == "1" then
			uci:set("totp", "main", "enabled", "0")
			uci:save("totp")
			uci:commit("totp")
		end
		st = setup_state()
		st.message = "新密钥已生成，启用已自动关闭；请扫码并验证后重新开启。"
	elseif action == "verify" then
		local code = http.formvalue("code") or ""
		local ip = luci.http.getenv("REMOTE_ADDR")
		local ok, reason = totp.verify_code(code, ip)
		if ok then
			set_bound(true)
			st = setup_state()
			st.message = "验证通过，绑定完成，现在可以开启用。"
		else
			local msg = "验证码不正确或已过期。"
			if reason == "locked" then msg = "失败次数过多，已锁定 5 分钟，请稍后再试。" end
			if reason == "replay" then msg = "该验证码已使用过，请用验证器上的新码。" end
			if reason == "not_configured" then msg = "密钥未生成，请先生成密钥。" end
			st.errmsg = msg
		end
	elseif action == "enable" then
		local want = http.formvalue("enabled") == "1"
		if want and not bound_exists() then
			st.errmsg = "请先扫码并验证通过，再开启用。"
		else
			uci:set("totp", "main", "enabled", want and "1" or "0")
			uci:save("totp")
			uci:commit("totp")
			local ok, out = run_patch(want and "apply" or "revert")
			st = setup_state()
			st.patch_output = out
			if want then
				if ok then st.message = "TOTP 已启用，登录补丁已打上。"
				else st.errmsg = "TOTP 已启用，但登录补丁未打上（已启用但未保护），请点“打补丁”重试或看下方输出。" end
			else
				if ok then st.message = "TOTP 已关闭，登录文件已恢复。"
				else st.errmsg = "TOTP 已关闭，但登录补丁恢复失败（登录可能仍要求验证码），请看下方输出或用 SSH 检查。" end
			end
		end
	elseif action == "patch_toggle" then
		local before = setup_state()
		local ok, out = run_patch(before.patch_applied and "revert" or "apply")
		st = setup_state()
		st.patch_output = out
		if ok then
			st.message = before.patch_applied and "登录文件已恢复，登录不再要求验证码。"
				or "登录补丁已打上，密码通过后将要求验证码。"
		else
			st.errmsg = "补丁操作未成功，当前保护状态见下方（未确认保护请勿当作已保护）。"
		end
	elseif action == "recovery" then
		local codes, hashes = totp.generate_recovery_codes(10)
		totp.store_recovery_hashes(hashes)
		local f = io.open(ONCE_FILE, "w")
		if f then f:write(table.concat(codes, "\n") .. "\n") f:close() end
		os.execute("chmod 600 " .. ONCE_FILE .. " 2>/dev/null")
		-- 一次性展示：本请求内读出并删除，刷新即不再显示。
		local rf = io.open(ONCE_FILE, "r")
		st.recovery_codes = rf and rf:read("*a") or ""
		if rf then rf:close() end
		os.remove(ONCE_FILE)
	elseif action == "advanced" then
		local function flag(name) return http.formvalue(name) == "1" and "1" or "0" end
		uci:set("totp", "main", "ssh_sync", flag("ssh_sync"))
		uci:set("totp", "main", "lan_bypass", flag("lan_bypass"))
		uci:delete("totp", "main", "lan_networks")
		local raw = http.formvalue("lan_networks") or ""
		for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
			local net = line:gsub("^%s+", ""):gsub("%s+$", "")
			-- 只接受 CIDR/地址字符，挡掉 HTML 与 shell 元字符。
			if net ~= "" and not net:match("[^0-9a-zA-Z%.%:/]") then
				uci:add_list("totp", "main", "lan_networks", net)
			end
		end
		uci:save("totp")
		uci:commit("totp")
		st = setup_state()
		st.message = "高级设置已保存。"
	end

	luci.template.render("totp/setup", st)
end

-- 公开第二步验证（顶层 totp/verify_login，登录补丁的步骤 2）。
-- 安全姿态（fail-closed）：
--   * 只认 totp_pending cookie 里的 token，且表单 hidden token 必须与
--     cookie 一致（双绑定，防 CSRF）；URL 里不带 token，token 只认 cookie。
--   * 任何一步失败（无 cookie、token 不一致、pending 缺失/过期、码不对）
--     都不发会话、不泄露原因细节；过期时服务端记录已清理（删文件 +
--     尽力销毁残留 sid），浏览器里的死 cookie 由下次登录覆盖。
--   * 通过后：消费 pending（删文件，token 一次性）→ 按 dispatcher 原生
--     写法发 sysauth cookie（名随 HTTPS、path=build_url()、SameSite=
--     strict、HttpOnly、HTTPS 时加 secure，与 dispatcher.uc 逐项对齐）
--     → 重定向到服务端存储的回程路径（段字符二次校验，非法回落根）。
--   * 注意 ucode http 的 header 表以键去重，两个 Set-Cookie 会互相覆盖：
--     成功时只发 sysauth 这一条，不再另发一条清 totp_pending（pending
--     文件已消费，浏览器里残留的 cookie 值已是死 token，无害）。
--   * 备用码 8 位先走备用码路径（用一次即废，LuCI 与 SSH 同步作废）；
--     错码计入 IP 限流（与 6 位码路径一致）；6 位码复用核心 verify_code
--     （±1 步、防重放、IP 限流 5 次/10 分钟锁 5 分钟）。
function verify_login()
	local http = require("luci.http")
	local totp = require("luci.totp")
	local post_url = luci.dispatcher.build_url("totp", "verify_login")
	local login_url = luci.dispatcher.build_url()
	local method = luci.http.getenv("REQUEST_METHOD") or ""
	local cookie_token = luci.http.getcookie("totp_pending") or ""
	local form_token = http.formvalue("token") or ""
	local code = http.formvalue("code") or ""

	local function render(state)
		state.post_url = post_url
		state.login_url = login_url
		luci.template.render("totp/verify-login", state)
	end

	local function expired()
		-- 只渲染过期页，不删记录：真正过期的记录在 peek 时已清理；
		-- 而 token 不一致时（陈旧标签页提交）绝不能删掉当前有效的
		-- pending，否则一次误提交会把新登录尝试也作废。
		render({ errmsg = "验证会话已过期，请重新登录。" })
	end

	local function issue_session(rec)
		local rec2 = totp.consume_pending_login(cookie_token)
		if not rec2 then expired() return end
		local https = luci.http.getenv("HTTPS") == "on"
		local name = https and "sysauth_https" or "sysauth_http"
		local secure = https and "; secure" or ""
		http.header("Set-Cookie", name .. "=" .. rec2.sid
			.. "; path=" .. login_url .. "; SameSite=strict; HttpOnly" .. secure)
		local dest = login_url
		if rec2.return_path and rec2.return_path ~= "" then
			local segs, ok = {}, true
			for seg in (rec2.return_path .. "/"):gmatch("([^/]*)/") do
				if seg == "" or seg == "." or seg == ".."
					or not seg:match("^[A-Za-z0-9_%%%.-]+$") then
					ok = false break
				end
				segs[#segs + 1] = seg
			end
			if ok and #segs > 0 then dest = luci.dispatcher.build_url(unpack(segs)) end
		end
		http.redirect(dest)
	end

	-- GET：无码时只渲染表单（须有有效 pending，否则直接报过期）。
	if method ~= "POST" or code == "" then
		if cookie_token == "" then expired() return end
		local rec = totp.peek_pending(cookie_token)
		if not rec then expired() return end
		if method ~= "POST" then
			render({ pending_token = cookie_token })
		else
			render({ errmsg = "请输入验证码。", pending_token = cookie_token })
		end
		return
	end

	-- POST：cookie 与表单 token 双绑定，任一缺失/不一致都按过期处理。
	if cookie_token == "" or form_token ~= cookie_token then expired() return end
	local rec = totp.peek_pending(cookie_token)
	if not rec then expired() return end
	local ip = luci.http.getenv("REMOTE_ADDR")
	if totp.is_locked(ip) then
		render({ errmsg = "失败次数过多，已锁定 5 分钟，请稍后再试。", pending_token = cookie_token })
		return
	end
	if #code == 8 and code:match("^%d+$") then
		local ok = totp.use_recovery_code(code)
		if ok then issue_session(rec) return end
		totp.record_fail(ip)
		render({ errmsg = "备用码不正确。", pending_token = cookie_token })
		return
	end
	if #code == 6 and code:match("^%d+$") then
		local ok, reason = totp.verify_code(code, ip)
		if ok then issue_session(rec) return end
		local msg = "验证码不正确或已过期。"
		if reason == "locked" then msg = "失败次数过多，已锁定 5 分钟，请稍后再试。" end
		if reason == "replay" then msg = "该验证码已使用过，请用验证器上的新码。" end
		if reason == "not_configured" then msg = "验证器未配置，拒绝登录（fail-closed）。" end
		render({ errmsg = msg, pending_token = cookie_token })
		return
	end
	render({ errmsg = "验证码格式不正确（6 位验证码或 8 位备用码）。", pending_token = cookie_token })
end
