#!/bin/sh
# totp-patch-login.sh -- LuCI 登录流程接管补丁（OpenWrt 25.12 真接管版）
# 用法：
#   totp-patch-login.sh apply    # 备份 + 插入功能性钩子，任一步失败即还原
#   totp-patch-login.sh revert   # 从备份恢复原文件字节，删除接管标记
#   totp-patch-login.sh status   # 只显示接管状态，不改文件
#
# 机制（OpenWrt 25.12 公开源码钉死，旧候选表已作废）：
#   * 登录在 /usr/share/ucode/luci/dispatcher.uc 的 dispatch() 里完成；
#     密码成功点是 session_setup() 调用行（全文件唯一）之后、Set-Cookie
#     发 sysauth 之前。旧脚本的候选表（dispatcher.lua、sysauth.htm、
#     login.htm）对 25.12 全错：dispatcher.lua 不存在（是 dispatcher.uc），
#     sysauth.htm 已是 ucode 模板 + 客户端 JS，login.htm 不存在。
#   * 补丁块（锚串 luci-totp-gate-v1）只做三件事：UCI enabled 检查、
#     Lua 桥 gate_step1 调用（单字符串返回）、按返回值分流：
#       "full"    -> 原流程不变（未启用 / 内网放行）
#       "pending" -> 设 totp_pending cookie + 重定向公开验证节点并 return
#       "deny"    -> 销毁 fresh 会话，落入原有 403 sysauth 分支
#     sid 在步骤 2 通过前绝不离开服务器（存在服务端 pending 文件里）。
#   * 步骤 2 在顶层公开节点 totp/verify_login（控制器 verify_login）完成，
#     通过后才按 dispatcher 原生写法发 sysauth cookie 并重定向回程路径。
#
# 安全原则（fail-closed）：
#   * 先备份（/etc/totp/backup/dispatcher.uc.<时间戳>.bak），再改文件；
#     锚行计数不恰好为 1、钩子已在、目标文件缺失，一律中止、不写文件。
#   * 标记 /etc/totp/patch-applied 仅在以下三项全过后才写：钩子锚串在
#     目标文件中恰好出现一次、luci.totp 含 gate_step1、验证模板在位。
#     只写标记、不改登录行为的“标记版”是假保护 bug，本脚本绝不产生。
#   * 状态判定同样是“标记与钩子缺一不可”：不一致时报异常警告，不显示已打。
#   * 本脚本不改密码、不改 SSH（SSH 由 totp-sync-ssh.sh 管）、不改 daed、
#     不改隧道；安装时绝不自动 apply（uci-defaults 里没有 apply 调用）。
#   * revert 恢复后用 cmp 校验与备份字节一致，并确认钩子锚串已消失。
set -eu

BACKUP_DIR="/etc/totp/backup"
MARKER="/etc/totp/patch-applied"
TARGET="/usr/share/ucode/luci/dispatcher.uc"
GATE_LUA="/usr/lib/lua/luci/totp.lua"
VERIFY_TMPL="/usr/lib/lua/luci/view/totp/verify-login.htm"
ANCHOR="session = session_setup(user, pass, resolved.ctx.request_path);"
HOOK_ID="luci-totp-gate-v1"

hook_present() {
	[ -f "$TARGET" ] && grep -q "$HOOK_ID" "$TARGET" 2>/dev/null
}

status() {
	marker=no; hook=no
	if [ -f "$MARKER" ]; then marker=yes; fi
	if hook_present; then hook=yes; fi
	echo "patched-marker: $marker"
	echo "patched-hook: $hook"
	if [ "$marker" = yes ]; then
		echo "marker: $(cat "$MARKER" 2>/dev/null)"
	fi
	if [ "$marker" = yes ] && [ "$hook" = yes ]; then
		echo "patched: yes (marker + hook agree)"
	elif [ "$marker" = no ] && [ "$hook" = no ]; then
		echo "patched: no"
	else
		echo "WARNING: marker/hook mismatch - login protection state is unclear."
		echo "Do NOT trust the settings page until this is resolved; inspect $TARGET manually."
	fi
}

do_apply() {
	mkdir -p "$BACKUP_DIR"
	if [ -f "$MARKER" ]; then
		echo "already patched, abort (revert first if you want to re-apply)"
		exit 1
	fi
	if hook_present; then
		echo "ABORT: hook anchor already present in $TARGET but no marker."
		echo "Refusing to write a marker over an unknown state; inspect manually."
		exit 2
	fi
	if [ ! -f "$TARGET" ]; then
		echo "ABORT: login file not found: $TARGET"
		echo "This LuCI generation does not match OpenWrt 25.12 layout; do not force-patch."
		exit 2
	fi
	anchor_count="$(grep -c -F "$ANCHOR" "$TARGET" 2>/dev/null || true)"
	if [ "$anchor_count" != "1" ]; then
		echo "ABORT: password-success anchor not unique (found: $anchor_count, want exactly 1)."
		echo "Do NOT force-patch. Inspect $TARGET manually on a test device."
		exit 2
	fi
	STAMP="$(date +%Y%m%d%H%M%S)"
	BACKUP="$BACKUP_DIR/dispatcher.uc.$STAMP.bak"
	cp "$TARGET" "$BACKUP"
	# 插入块（写临时文件，失败即还原，绝不留半成品）：
	BLOCK="$(mktemp /tmp/totp-patch-block.XXXXXX)"
	trap 'rm -f "$BLOCK" "$TARGET.new"; cp "$BACKUP" "$TARGET" 2>/dev/null || true' EXIT
	cat > "$BLOCK" <<'UCBLOCK'
				/* luci-totp-gate-v1: TOTP second step (see luci.totp.gate_step1).
				   Password already verified by session_setup() above; this block
				   only decides whether the fresh session may be issued now.
				   "full"    -> fall through to the original Set-Cookie + redirect.
				   "pending" -> hold the sid server-side, set totp_pending cookie,
				                redirect to the public verify node, return.
				   "deny"    -> destroy the fresh session, fall into the original
				                403 sysauth branch below (generic failure text). */
				if (session) {
					let totp_gate = null;

					if (uci.get('totp', 'main', 'enabled') == '1') {
						if (load_luabridge(true)) {
							try {
								totp_gate = runtime.call('luci.totp', 'gate_step1',
									session.data?.username ?? user,
									session.sid,
									join('/', resolved.ctx.request_path),
									http.getenv('REMOTE_ADDR'),
									http.getenv('HTTP_HOST'));
							} catch (e) {
								totp_gate = 'deny';
							}
						} else {
							totp_gate = 'deny';
						}
					}

					if (type(totp_gate) == 'string' && substr(totp_gate, 0, 8) == 'pending:') {
						http.header('Set-Cookie', `totp_pending=${substr(totp_gate, 8)}; path=${build_url()}; SameSite=strict; HttpOnly${(http.getenv('HTTPS') == 'on') ? '; secure' : ''}`);
						http.redirect(build_url('totp', 'verify_login'));

						return;
					} else if (totp_gate == 'deny') {
						ubus.call('session', 'destroy', { ubus_rpc_session: session.sid });
						session = null;
					}
				}
UCBLOCK
	lineno="$(grep -n -F "$ANCHOR" "$TARGET" | cut -d: -f1)"
	{ head -n "$lineno" "$TARGET"; cat "$BLOCK"; tail -n +"$((lineno + 1))" "$TARGET"; } > "$TARGET.new"
	cat "$TARGET.new" > "$TARGET"
	rm -f "$TARGET.new"
	# 验证三项，全过才写标记；任一项不过即还原备份并中止：
	hook_count="$(grep -c "$HOOK_ID" "$TARGET" 2>/dev/null || true)"
	anchor_after="$(grep -c -F "$ANCHOR" "$TARGET" 2>/dev/null || true)"
	gate_ok=no; tmpl_ok=no
	if grep -q "function gate_step1" "$GATE_LUA" 2>/dev/null; then gate_ok=yes; fi
	if [ -f "$VERIFY_TMPL" ]; then tmpl_ok=yes; fi
	if [ "$hook_count" != "1" ] || [ "$anchor_after" != "1" ] \
		|| [ "$gate_ok" != "yes" ] || [ "$tmpl_ok" != "yes" ]; then
		echo "ABORT: post-insert verification failed (hook=$hook_count anchor=$anchor_after gate=$gate_ok template=$tmpl_ok)."
		echo "Restoring backup; no marker written, login untouched."
		cp "$BACKUP" "$TARGET"
		exit 3
	fi
	echo "$STAMP $TARGET" > "$MARKER"
	trap - EXIT
	rm -f "$BLOCK"
	rm -f /tmp/luci-indexcache.*.json 2>/dev/null || true
	echo "patched: $TARGET (backup: $BACKUP)"
	echo "Next: keep your current session open, test login in a SEPARATE browser"
	echo "session (do not close the current one), and keep backup codes ready."
	echo "To undo: $0 revert"
}

do_revert() {
	if [ ! -f "$MARKER" ]; then
		if hook_present; then
			echo "ERROR: hook present but no marker; refusing to guess."
			echo "Inspect $TARGET manually."
			exit 1
		fi
		echo "not patched, nothing to revert"
		exit 0
	fi
	latest="$(ls -t "$BACKUP_DIR"/dispatcher.uc.*.bak 2>/dev/null | head -1 || true)"
	if [ -z "$latest" ]; then
		echo "ERROR: marker exists but no dispatcher.uc backup found; refusing to guess."
		echo "Restore manually from $BACKUP_DIR/."
		exit 1
	fi
	cat "$latest" > "$TARGET"
	if ! cmp -s "$latest" "$TARGET"; then
		echo "ERROR: restored file differs from backup; login file left as restored copy."
		echo "Inspect $TARGET and $latest manually before retrying."
		exit 1
	fi
	if hook_present; then
		echo "ERROR: hook anchor still present after restore; refusing to clear marker."
		exit 1
	fi
	rm -f "$MARKER"
	rm -f /tmp/luci-indexcache.*.json 2>/dev/null || true
	echo "reverted from $latest to $TARGET (byte-identical to backup)"
}

case "${1:-status}" in
	apply) do_apply ;;
	revert) do_revert ;;
	status) status ;;
	*) echo "usage: $0 {apply|revert|status}"; exit 1 ;;
esac
