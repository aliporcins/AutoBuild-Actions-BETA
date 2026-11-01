-- luci.totp -- LuCI 验证器插件核心：纯 Lua TOTP（RFC 6238 / RFC 4226）
-- 实验版，不依赖 LuCI 运行时（除文件读写与 chmod 外），可在普通 Lua 5.1 下单测。
-- 设计口径：
--   * 算法：TOTP，6 位、30 秒一步、SHA1、容差 ±1 步（即当前步前后各一步），
--     与谷歌验证器及其他标准 TOTP 应用兼容。
--   * 密钥：Base32，生成时 16 字符（10 字节，80 位，谷歌验证器常见长度）；
--     校验时接受任意合法 Base32 长度。
--   * 失败即锁死（fail-closed）：密钥缺失、时间漂移超窗、加密失败、文件损坏
--     一律拒绝，不放行。
--   * 防重放：上次成功使用的计数器写入 LAST_FILE，计数器 <= 上次值一律拒绝，
--     同一步内的验证码只能用一次。
--   * 限流：同一 IP 10 分钟内失败 5 次后锁定 5 分钟（文件在 FAIL_DIR，重启后
--     清空是已知限制，见 README；生产门 luci-gate 的限流仍在前面挡着）。
--   * 密钥与备用码的存放（见 README“存放口径”）：
--       密钥          /etc/totp/secret          600 root
--       备用码哈希    /etc/totp/recovery.sha1   600 root（SHA1 哈希，见下注）
--       上次计数器    /etc/totp/last-counter    600 root
--       待验证会话    /var/lib/totp-pending/    700 root
--       SSH 同步文件  /root/.google_authenticator 600 root（仅 SSH 同步开启时）
--   * 注：备用码哈希用 SHA1 是原型取舍（复用本文件已有的 SHA1，不再引入第
--     二套哈希实现）；备用码本身是 8 位数字高熵随机码，SHA1 原像攻击在此
--     场景下不构成实际威胁。生产版建议改用 nixio.crypto / openssl 的 SHA256。
--   * 本文件不含任何真实密钥、密码、备用码；测试用密钥均为 RFC 公开向量。
module("luci.totp", package.seeall)

local MOD32 = 4294967296 -- 2^32

-- ---------- 32 位无符号算术位运算（纯 Lua 5.1，无 bit 库依赖） ----------
local function band(a, b)
	local r, p = 0, 1
	for _ = 1, 32 do
		if a % 2 == 1 and b % 2 == 1 then r = r + p end
		a, b, p = math.floor(a / 2), math.floor(b / 2), p * 2
	end
	return r
end

local function bor(a, b)
	local r, p = 0, 1
	for _ = 1, 32 do
		if a % 2 == 1 or b % 2 == 1 then r = r + p end
		a, b, p = math.floor(a / 2), math.floor(b / 2), p * 2
	end
	return r
end

local function bxor(a, b)
	local r, p = 0, 1
	for _ = 1, 32 do
		if (a % 2) ~= (b % 2) then r = r + p end
		a, b, p = math.floor(a / 2), math.floor(b / 2), p * 2
	end
	return r
end

local function bnot(a) return (MOD32 - 1) - a end
local function lshift(a, n) return (a * (2 ^ n)) % MOD32 end
local function rshift(a, n) return math.floor(a / (2 ^ n)) end
local function rol(a, n)
	n = n % 32
	if n == 0 then return a end
	return ((a * (2 ^ n)) % MOD32) + math.floor(a / (2 ^ (32 - n)))
end

-- ---------- SHA1（FIPS 180-1，纯 Lua，显式轮换实现） ----------
local function sha1_impl(msg)
	local ml = #msg
	local padlen = (56 - (ml + 1) % 64) % 64
	local data = msg .. string.char(0x80) .. string.rep("\0", padlen)
	local bitlen = ml * 8
	for i = 7, 0, -1 do
		data = data .. string.char(math.floor(bitlen / (256 ^ i)) % 256)
	end
	local h = { 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0 }
	for off = 1, #data, 64 do
		local w = {}
		for i = 0, 15 do
			local b = off + i * 4
			w[i + 1] = data:byte(b) * 16777216 + data:byte(b + 1) * 65536
				+ data:byte(b + 2) * 256 + data:byte(b + 3)
		end
		for i = 17, 80 do
			w[i] = rol(bxor(bxor(w[i - 3], w[i - 8]), bxor(w[i - 14], w[i - 16])), 1)
		end
		local a, b, c, d, e = h[1], h[2], h[3], h[4], h[5]
		for i = 1, 80 do
			local f, k
			if i <= 20 then
				f = bor(band(b, c), band(bnot(b), d)); k = 0x5A827999
			elseif i <= 40 then
				f = bxor(bxor(b, c), d); k = 0x6ED9EBA1
			elseif i <= 60 then
				f = bor(bor(band(b, c), band(b, d)), band(c, d)); k = 0x8F1BBCDC
			else
				f = bxor(bxor(b, c), d); k = 0xCA62C1D6
			end
			local tmp = (rol(a, 5) + f + e + k + w[i]) % MOD32
			-- 标准轮换：e=d, d=c, c=rol(b,30), b=a, a=tmp
			local na, nb, nc, nd, ne = tmp, a, rol(b, 30), c, d
			a, b, c, d, e = na, nb, nc, nd, ne
		end
		h[1] = (h[1] + a) % MOD32
		h[2] = (h[2] + b) % MOD32
		h[3] = (h[3] + c) % MOD32
		h[4] = (h[4] + d) % MOD32
		h[5] = (h[5] + e) % MOD32
	end
	local out = {}
	for i = 1, 5 do
		local v = h[i]
		out[#out + 1] = string.char(
			math.floor(v / 16777216) % 256,
			math.floor(v / 65536) % 256,
			math.floor(v / 256) % 256,
			v % 256)
	end
	return table.concat(out)
end

local function tohex(s)
	local t = {}
	for i = 1, #s do t[#t + 1] = string.format("%02x", s:byte(i)) end
	return table.concat(t)
end

local function hmac_sha1(key, msg)
	if #key > 64 then key = sha1_impl(key) end
	key = key .. string.rep("\0", 64 - #key)
	local ipad, opad = {}, {}
	for i = 1, 64 do
		local kb = key:byte(i)
		ipad[i] = string.char(bxor(kb, 0x36))
		opad[i] = string.char(bxor(kb, 0x5C))
	end
	return sha1_impl(table.concat(opad) .. sha1_impl(table.concat(ipad) .. msg))
end

-- ---------- Base32 ----------
local B32_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
local B32_MAP = {}
for i = 1, #B32_ALPHABET do B32_MAP[B32_ALPHABET:sub(i, i)] = i - 1 end

function base32_decode(s)
	s = (s or ""):upper():gsub("[%s=]", "")
	local bits, nbits, out = 0, 0, {}
	for i = 1, #s do
		local v = B32_MAP[s:sub(i, i)]
		if v == nil then return nil, "invalid_base32" end
		bits = bits * 32 + v
		nbits = nbits + 5
		if nbits >= 8 then
			nbits = nbits - 8
			out[#out + 1] = string.char(math.floor(bits / (2 ^ nbits)) % 256)
			bits = bits % (2 ^ nbits)
		end
	end
	return table.concat(out)
end

function base32_encode(data)
	local bits, nbits, out = 0, 0, {}
	for i = 1, #data do
		bits = bits * 256 + data:byte(i)
		nbits = nbits + 8
		while nbits >= 5 do
			nbits = nbits - 5
			out[#out + 1] = B32_ALPHABET:sub(math.floor(bits / (2 ^ nbits)) % 32 + 1, math.floor(bits / (2 ^ nbits)) % 32 + 1)
			bits = bits % (2 ^ nbits)
		end
	end
	if nbits > 0 then
		out[#out + 1] = B32_ALPHABET:sub((bits * (2 ^ (5 - nbits))) % 32 + 1, (bits * (2 ^ (5 - nbits))) % 32 + 1)
	end
	return table.concat(out)
end

-- ---------- TOTP ----------
function totp_at(secret_b32, time_sec, digits)
	digits = digits or 6
	local key, err = base32_decode(secret_b32)
	if not key then return nil, err end
	local counter = math.floor((time_sec or os.time()) / 30)
	local hi = math.floor(counter / MOD32)
	local lo = counter % MOD32
	local msg = string.char(
		math.floor(hi / 16777216) % 256, math.floor(hi / 65536) % 256,
		math.floor(hi / 256) % 256, hi % 256,
		math.floor(lo / 16777216) % 256, math.floor(lo / 65536) % 256,
		math.floor(lo / 256) % 256, lo % 256)
	local hs = hmac_sha1(key, msg)
	local offset = hs:byte(20) % 16
	local binary = bor(
		bor(lshift(band(hs:byte(offset + 1), 0x7F), 24), lshift(hs:byte(offset + 2), 16)),
		bor(lshift(hs:byte(offset + 3), 8), hs:byte(offset + 4)))
	local code = binary % (10 ^ digits)
	return string.format("%0" .. digits .. "d", code), counter
end

-- ---------- 文件与路径（测试可覆盖） ----------
local PATHS = {
	secret = "/etc/totp/secret",
	recovery = "/etc/totp/recovery.sha1",
	last = "/etc/totp/last-counter",
	fail_dir = "/var/lib/totp-fail",
	pending_dir = "/var/lib/totp-pending",
	google_auth = "/root/.google_authenticator",
}

function set_paths(p)
	for k, v in pairs(p or {}) do PATHS[k] = v end
	return PATHS
end

function get_paths() return PATHS end

local function read_file(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local data = f:read("*a")
	f:close()
	return data
end

local function write_file_secure(path, data)
	-- 原子写：写临时文件 -> chmod 600 -> 改名，避免半写文件被读到。
	local dir = path:match("^(.*)/[^/]*$") or "."
	os.execute("mkdir -p '" .. dir .. "' 2>/dev/null")
	local tmp = path .. ".tmp"
	local f = io.open(tmp, "wb")
	if not f then return false, "cannot_write" end
	f:write(data)
	f:close()
	os.execute("chmod 600 '" .. tmp .. "' 2>/dev/null")
	os.rename(tmp, path)
	return true
end

local function trim(s)
	-- 注意：gsub 返回两个值（结果 + 替换次数），直接 return gsub(...) 会把
	-- 次数也带出去，导致 tonumber(trim(x)) 把次数当成进制而报错。
	-- 这里用单变量赋值截断为一个返回值。
	s = (s or ""):gsub("^%s+", "")
	s = s:gsub("%s+$", "")
	return s
end

function get_secret()
	local data = read_file(PATHS.secret)
	if not data then return nil end
	return trim(data)
end

function set_secret(secret)
	return write_file_secure(PATHS.secret, secret .. "\n")
end

local function random_bytes(n)
	local f = io.open("/dev/urandom", "rb")
	if f then
		local data = f:read(n)
		f:close()
		if data and #data == n then return data end
	end
	-- 回退（仅在无 /dev/urandom 时，路由器上不应走到这里；README 有说明）：
	math.randomseed(os.time() + os.clock() * 1000000)
	local t = {}
	for _ = 1, n do t[#t + 1] = string.char(math.random(0, 255)) end
	return table.concat(t)
end

function generate_secret()
	-- 10 字节 -> 16 个 Base32 字符，与谷歌验证器默认长度一致。
	return base32_encode(random_bytes(10))
end

function otpauth_uri(secret, account, issuer)
	account = account or "root"
	issuer = issuer or "OpenWrt"
	return "otpauth://totp/" .. issuer .. ":" .. account
		.. "?secret=" .. secret .. "&issuer=" .. issuer
		.. "&digits=6&period=30&algorithm=SHA1"
end

-- ---------- 备用码 ----------
function generate_recovery_codes(count)
	count = count or 10
	local codes, hashes = {}, {}
	for _ = 1, count do
		local code = ""
		for _ = 1, 8 do code = code .. tostring(math.random(0, 9)) end
		-- 用 /dev/urandom 重抽，避免 math.random 序列可预测：
		local rb = random_bytes(8)
		code = ""
		for i = 1, 8 do code = code .. tostring(rb:byte(i) % 10) end
		codes[#codes + 1] = code
		hashes[#hashes + 1] = tohex(sha1_impl(code))
	end
	return codes, hashes
end

function store_recovery_hashes(hashes)
	return write_file_secure(PATHS.recovery, table.concat(hashes, "\n") .. "\n")
end

function use_recovery_code(code)
	-- 备用码：命中哈希即作废（删行），同时删 SSH 同步文件里的同一明文码
	-- （若该文件存在），保证 LuCI 与 SSH 两边同一码只能用一次。
	code = trim(code or "")
	if #code ~= 8 or not code:match("^%d+$") then return false, "invalid" end
	local data = read_file(PATHS.recovery)
	if not data then return false, "no_recovery" end
	local target = tohex(sha1_impl(code))
	local kept, found = {}, false
	for line in (data .. "\n"):gmatch("([^\n]*)\n") do
		local h = trim(line)
		if h ~= "" then
			if h == target and not found then found = true else kept[#kept + 1] = h end
		end
	end
	if not found then return false, "invalid" end
	write_file_secure(PATHS.recovery, table.concat(kept, "\n") .. (kept[1] and "\n" or ""))
	-- 同步作废 SSH 文件里的同一码（文件不存在则跳过，不报错）：
	local ga = read_file(PATHS.google_auth)
	if ga then
		local lines, changed = {}, false
		for line in (ga .. "\n"):gmatch("([^\n]*)\n") do
			if trim(line) == code then changed = true else lines[#lines + 1] = line end
		end
		if changed then write_file_secure(PATHS.google_auth, table.concat(lines, "\n")) end
	end
	return true, "ok"
end

-- ---------- 限流 ----------
local function fail_path(ip)
	ip = (ip or "unknown"):gsub("[^%w%.:%-]", "_")
	return PATHS.fail_dir .. "/" .. ip
end

function is_locked(ip)
	local data = read_file(fail_path(ip))
	if not data then return false end
	local count, first, last = data:match("^(%d+)%s+(%d+)%s+(%d+)")
	count, first = tonumber(count) or 0, tonumber(first) or 0
	local now = os.time()
	if count >= 5 and now - first < 600 and now - (tonumber(last) or 0) < 300 then
		return true
	end
	if now - first >= 600 then return false end -- 窗口外，record_fail 会重置
	return false
end

function record_fail(ip)
	local now = os.time()
	local data = read_file(fail_path(ip))
	local count, first = 0, now
	if data then
		local c, f = data:match("^(%d+)%s+(%d+)")
		if c and f and now - tonumber(f) < 600 then count, first = tonumber(c), tonumber(f) end
	end
	os.execute("mkdir -p '" .. PATHS.fail_dir .. "' 2>/dev/null")
	write_file_secure(fail_path(ip), string.format("%d %d %d\n", count + 1, first, now))
end

function reset_fail(ip)
	os.remove(fail_path(ip))
end

-- ---------- 校验（含防重放与限流） ----------
function verify_code(code, ip, time_sec)
	code = trim(code or "")
	if #code ~= 6 or not code:match("^%d+$") then return false, "invalid_format" end
	if ip and is_locked(ip) then return false, "locked" end
	local secret = get_secret()
	if not secret or secret == "" then return false, "not_configured" end -- fail-closed
	local now = time_sec or os.time()
	local last_data = read_file(PATHS.last)
	local last_counter = last_data and tonumber(trim(last_data)) or nil
	for step = -1, 1 do
		local expected, counter = totp_at(secret, now + step * 30, 6)
		if expected and expected == code then
			if last_counter and counter <= last_counter then
				return false, "replay"
			end
			write_file_secure(PATHS.last, tostring(counter) .. "\n")
			if ip then reset_fail(ip) end
			return true, "ok"
		end
	end
	if ip then record_fail(ip) end
	return false, "invalid"
end

-- ---------- 待验证会话（密码通过后、验证码通过前） ----------
function create_pending(username)
	os.execute("mkdir -p '" .. PATHS.pending_dir .. "' 2>/dev/null")
	os.execute("chmod 700 '" .. PATHS.pending_dir .. "' 2>/dev/null")
	local token = tohex(sha1_impl(random_bytes(16) .. tostring(os.time()) .. (username or "")))
	write_file_secure(PATHS.pending_dir .. "/" .. token,
		(username or "") .. "\n" .. tostring(os.time() + 300) .. "\n")
	return token
end

function check_pending(token)
	if not token or not token:match("^[0-9a-f]+$") then return nil end
	local data = read_file(PATHS.pending_dir .. "/" .. token)
	if not data then return nil end
	local username, exp = data:match("^([^\n]*)\n(%d+)")
	if not username or not exp or os.time() > tonumber(exp) then
		os.remove(PATHS.pending_dir .. "/" .. token)
		return nil
	end
	return username
end

function consume_pending(token)
	local username = check_pending(token)
	if username then os.remove(PATHS.pending_dir .. "/" .. token) end
	return username
end

-- ---------- 登录接管门（25.12 ucode dispatcher 补丁块调用） ----------
-- 机制（OpenWrt 25.12，公开源码已钉死，见 README 第 5 节）：
--   * 登录在 /usr/share/ucode/luci/dispatcher.uc 的 dispatch() 里完成：
--     session_setup()（ubus session login + session set token）成功后、
--     Set-Cookie 发 sysauth 之前，是唯一密码成功点。补丁块
--     （luci-totp-gate-v1）就插在 session_setup 调用行之后。
--   * gate_step1 由补丁块经 Lua 桥 runtime.call 调用，返回值必须是单个
--     字符串（桥多返回值可能丢失，故不用多值返回）：
--       "full"            -> 未启用或内网放行，按原流程立即发完整会话
--       "deny"            -> 拒绝登录（无密钥、参数非法）；ucode 侧销毁
--                            fresh 会话后落入原有 403 sysauth 分支
--       "pending:<token>" -> 待验证会话已建；ucode 侧只把 token 发
--                            totp_pending cookie 并重定向到公开验证节点。
--     sid 在步骤 2 通过前绝不离开服务器：pending 文件（700 目录、600
--     文件）第 3 行存 sid，浏览器只拿到随机 token。
--   * bound 标记不是门条件（它只是设置页流程守卫）；安全属性是密钥本身。
--     enabled=1 但未绑定的手改 UCI 状态下仍设门（密钥在页上可扫）；
--     密钥缺失才拒绝（fail-closed）。
--   * 待验证会话文件 v2 格式（兼容旧解析：旧 check_pending 只读前两行）：
--       第 1 行 用户名 / 第 2 行 过期时间 / 第 3 行 sid / 第 4 行 回程路径
--     回程路径是 dispatcher 的 request_path 段 join 后的串（空表示根）；
--     段字符在 gate 与步骤 2 两处各校验一次，非法段一律回落到根。
local function valid_sid(sid)
	return type(sid) == "string" and sid:match("^[0-9a-f]+$") ~= nil
end

local function valid_return_path(p)
	if type(p) ~= "string" or p == "" then return "" end
	local segs = {}
	for seg in (p .. "/"):gmatch("([^/]*)/") do
		if seg == "" or seg == "." or seg == ".."
			or not seg:match("^[A-Za-z0-9_%%%.-]+$") then
			return ""
		end
		segs[#segs + 1] = seg
	end
	if #segs == 0 then return "" end
	return table.concat(segs, "/")
end

local function destroy_rpcd_session(sid)
	-- 尽力而为：ubus 不在或调用失败时忽略（残留会话只剩 rpcd 自身的
	-- sessiontime 超时，且浏览器从未拿到 sid，无法被使用）。
	if not valid_sid(sid) then return end
	os.execute("ubus call session destroy '{\"ubus_rpc_session\":\""
		.. sid .. "\"}' >/dev/null 2>&1")
end

local function expire_stale_pending()
	local pipe = io.popen("ls -1 '" .. PATHS.pending_dir .. "' 2>/dev/null")
	if not pipe then return end
	for name in pipe:lines() do
		-- 只碰本插件自己生成的十六进制 token 文件名，余者一律不动。
		if name:match("^[0-9a-f]+$") then
			local data = read_file(PATHS.pending_dir .. "/" .. name)
			if data then
				local _, exp, sid = data:match("^([^\n]*)\n(%d+)\n([^\n]*)")
				if not exp or os.time() > tonumber(exp) then
					if sid and valid_sid(sid) then destroy_rpcd_session(sid) end
					os.remove(PATHS.pending_dir .. "/" .. name)
				end
			end
		end
	end
	pipe:close()
end

function create_pending_login(username, sid, return_path)
	if type(username) ~= "string" or username == "" then return nil end
	if username:match("[\r\n]") then return nil end -- 用户名绝不能断行（文件格式）
	if not valid_sid(sid) then return nil end
	os.execute("mkdir -p '" .. PATHS.pending_dir .. "' 2>/dev/null")
	os.execute("chmod 700 '" .. PATHS.pending_dir .. "' 2>/dev/null")
	local token = tohex(sha1_impl(random_bytes(16) .. tostring(os.time()) .. username))
	local ok = write_file_secure(PATHS.pending_dir .. "/" .. token,
		username .. "\n" .. tostring(os.time() + 300) .. "\n"
		.. sid .. "\n" .. valid_return_path(return_path) .. "\n")
	if not ok then return nil end
	return token
end

-- 只读不删：返回记录表或 nil + 原因。过期/损坏的记录在此处清理
-- （删文件 + 尽力销毁残留 sid），fail-closed。
function peek_pending(token)
	if not token or not token:match("^[0-9a-f]+$") then return nil, "invalid" end
	local data = read_file(PATHS.pending_dir .. "/" .. token)
	if not data then return nil, "missing" end
	local username, exp, sid, rp = data:match("^([^\n]*)\n(%d+)\n([^\n]*)\n([^\n]*)")
	if not username or username == "" or not exp
		or os.time() > tonumber(exp) or not valid_sid(sid) then
		if sid and valid_sid(sid) then destroy_rpcd_session(sid) end
		os.remove(PATHS.pending_dir .. "/" .. token)
		return nil, "expired"
	end
	return { username = username, expiry = tonumber(exp),
		sid = sid, return_path = rp or "" }
end

function consume_pending_login(token)
	local rec = peek_pending(token)
	if rec then os.remove(PATHS.pending_dir .. "/" .. token) end
	return rec
end

-- 显式作废（过期页展示时调用）：有效记录也销毁 sid + 删文件。
function expire_pending(token)
	local rec = peek_pending(token)
	if rec then
		destroy_rpcd_session(rec.sid)
		os.remove(PATHS.pending_dir .. "/" .. token)
		return true
	end
	return false
end

-- ucode 补丁块的唯一入口：单字符串返回 "full" / "deny" / "pending:<token>"。
function gate_step1(username, sid, return_path, ip, host)
	pcall(expire_stale_pending) -- 清过期是尽力而为，绝不因此坏门
	if type(username) ~= "string" or username == "" then return "deny" end
	if not valid_sid(sid) then return "deny" end
	local uci_ok, uci_mod = pcall(require, "luci.model.uci")
	if not uci_ok or not uci_mod then return "deny" end
	local cur = uci_mod.cursor()
	if not cur then return "deny" end
	if cur:get("totp", "main", "enabled") ~= "1" then return "full" end
	local secret = get_secret()
	if not secret or secret == "" then return "deny" end
	local networks = cur:get_list("totp", "main", "lan_networks")
	if not networks or #networks == 0 then networks = nil end -- 空表回落默认段
	local bypass = is_lan_bypass(ip, host, {
		enabled = cur:get("totp", "main", "lan_bypass") == "1",
		networks = networks,
	})
	if bypass then return "full" end
	local token = create_pending_login(username, sid, return_path)
	if not token then return "deny" end
	return "pending:" .. token
end

-- ---------- 内网放行（LAN bypass）：内网直连只跳过 TOTP，不跳过密码 ----------
-- 用户要求：从内网访问 LuCI 时不用这个门，只有从外网进来时才要验证器。
-- 判定口径（fail-closed，缺一不可，且公网域名一票否决）：
--   放行  <=>  lan_bypass 开关开
--            且 源 IP 是受信内网段内（或回环）
--            且 请求 Host 是内网地址（受信段内 IP、回环 IP、localhost）
--            且 Host 不是公网域名
-- 为什么必须两条都满足（不能只用一条）：
--   * 只看源 IP 会被隧道流量骗过：Cloudflare 隧道进来的请求在路由器侧
--     看起来可能像本地/回环（cloudflared 本机回连 uhttpd），源 IP 本地
--     不等于用户在内网。
--   * 只看 Host 会被伪造：Host 头是客户端可控的，隧道外的攻击者也能
--     把 Host 写成 192.168.2.1；只有同时源 IP 也在受信段内才可信。
--   * 公网域名一票否决：Host 是域名（除 localhost 外）时一律走 TOTP，
--     哪怕源 IP 看起来是本地——隧道流量正是这种情况，绝不能放行。
-- 其他硬规则：
--   * X-Forwarded-For 一律不采信（客户端可控）：只用 uhttpd 的 REMOTE_ADDR
--     与请求 Host（HTTP_HOST）做判定。
--   * 无法判定来源（IP 或 Host 缺失、格式非法）一律走 TOTP，绝不因判断
--     不出就放行。
--   * 默认受信段只放用户家里主 LAN：192.168.2.0/24。绝不默认放 10/8、
--     172.16/12、192.168/16 全段，更不放访客网段；要扩段须管理员在 UCI
--     里显式加（list lan_networks），扩段即扩大信任面，须自行负责。
--   * 关放行开关（lan_bypass=0）或停用插件时，内网与外网一律恢复原登录
--     流程（密码 + TOTP），不存在“关了开关还放行”的状态。
--   * 放行只跳过 TOTP 第二步：密码校验仍必须通过；内网放行不是免密码。
--   * IPv6：除回环 ::1 外不视为受信（用户主 LAN 是 IPv4；IPv6 内网段
--     如需放行，须管理员显式评估后再扩展本函数，不要默认放行）。
DEFAULT_TRUSTED_NETWORKS = { "192.168.2.0/24" }

local function parse_ipv4(ip)
	if type(ip) ~= "string" then return nil end
	local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	if not a then return nil end
	a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
	if a > 255 or b > 255 or c > 255 or d > 255 then return nil end
	return a * 16777216 + b * 65536 + c * 256 + d
end

local function parse_cidr(cidr)
	if type(cidr) ~= "string" then return nil end
	local ip, prefix = cidr:match("^%s*(.-)%s*/%s*(%d+)%s*$")
	if not ip then
		-- 不带掩码的裸 IP 视为 /32
		local num = parse_ipv4(trim(cidr))
		if num then return num, 32 end
		return nil
	end
	local num = parse_ipv4(ip)
	prefix = tonumber(prefix)
	if not num or not prefix or prefix < 0 or prefix > 32 then return nil end
	return num, prefix
end

local function ip_in_cidr(ip, cidr)
	local ipnum = parse_ipv4(ip)
	local net, prefix = parse_cidr(cidr)
	if not ipnum or not net then return false end
	local block = 2 ^ (32 - prefix)
	return math.floor(ipnum / block) == math.floor(net / block)
end

local function is_loopback_ip(ip)
	if ip == "127.0.0.1" or ip == "::1" then return true end
	-- 回环段 127.0.0.0/8（本机回连、隧道本机回连都落在这里；单独它
	-- 不构成放行，还须 Host 同时是内网地址，见 is_lan_bypass）。
	return type(ip) == "string" and ip:match("^127%.%d+%.%d+%.%d+$") ~= nil
end

function ip_in_networks(ip, networks)
	if is_loopback_ip(ip) then return true end
	for _, cidr in ipairs(networks or {}) do
		if ip_in_cidr(ip, cidr) then return true end
	end
	return false
end

local function normalize_host(host)
	if type(host) ~= "string" then return "" end
	host = trim(host):lower()
	host = host:gsub("%.$", "") -- 去掉末尾的点（如 "example.com."）
	if host:sub(1, 1) == "[" then
		-- [::1]:8080 或 [192.168.2.1]:80
		local inner = host:match("^%[([^%]]+)%]")
		return inner or ""
	end
	-- 裸 IPv6 含多个冒号，不拆端口；IPv4/域名带单个 :port 时拆掉端口。
	if host:match("^[^:]+:%d+$") then
		host = host:match("^(.*):%d+$")
	end
	return host
end

function is_lan_host(host, networks)
	local h = normalize_host(host)
	if h == "" then return false end
	if h == "localhost" then return true end
	if is_loopback_ip(h) then return true end
	return parse_ipv4(h) ~= nil and ip_in_networks(h, networks)
end

local function is_dns_host(host)
	local h = normalize_host(host)
	if h == "" or h == "localhost" then return false end
	-- 含字母即域名（公网域名与内网 .lan 名都在此列；.lan 名不被接受
	-- 为内网证明，见下：Host 头可伪造，.lan 名不能单独证明内网直连，
	-- 内网用户请用 LAN IP 或 localhost 访问）。
	return h:match("[a-z]") ~= nil
end

-- 放行判定：返回 (是否放行, 原因字符串)。原因只用于日志/排障，不含密钥。
function is_lan_bypass(ip, host, opts)
	opts = opts or {}
	if not opts.enabled then return false, "disabled" end
	if not ip or trim(ip) == "" or not host or trim(host) == "" then
		return false, "undetermined"
	end
	local networks = opts.networks or DEFAULT_TRUSTED_NETWORKS
	-- 公网域名一票否决：隧道流量（源 IP 看似本地 + 公网域名 Host）正在此列。
	if is_dns_host(host) then return false, "public_host" end
	if not is_lan_host(host, networks) then return false, "host_not_lan" end
	if not ip_in_networks(trim(ip), networks) then return false, "ip_not_trusted" end
	return true, "lan"
end

-- 反向口径：是否要求 TOTP（内网放行时为 false，其余一律 true）。
function should_require_totp(ip, host, opts)
	local bypass = is_lan_bypass(ip, host, opts)
	return not bypass
end

-- 供单测与外部调用的底层函数（不依赖 LuCI）：
sha1_hex = function(s) return tohex(sha1_impl(s)) end
hmac_sha1_hex = function(k, m) return tohex(hmac_sha1(k, m)) end
