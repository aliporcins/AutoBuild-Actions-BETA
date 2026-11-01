#!/bin/sh
# totp-sync-ssh.sh -- LuCI 验证器与 SSH 的同步（OpenSSH + PAM 路线，实验版）
# 用法：
#   totp-sync-ssh.sh sync [--first-factor=key|password]
#   totp-sync-ssh.sh disable
#
# 路线结论（先说清楚，见 README“SSH 路线”）：
#  * OpenWrt 默认的 Dropbear 不走 PAM：OpenWrt 默认构建未开 PAM，且上游
#    Dropbear 的 PAM 支持即使重编开启，也只支持简单“Login:/Password:”
#    对话，走不了谷歌验证器需要的 challenge/response（验证码二次提问）。
#    所以 Dropbear 路线不可行，不要硬编一个 Dropbear PAM 方案。
#  * 可行路线：停用 Dropbear，改用 OpenSSH（openssh-server-pam），
#    PAM 栈里加 pam_google_authenticator.so，密钥文件与 LuCI 共用同一
#    Base32 密钥（/etc/totp/secret -> /root/.google_authenticator 首行），
#    用户只扫一次码。
#  * 恢复路径：备用码可用（LuCI 与 SSH 同步作废）、密钥文件 600 仅 root、
#    停用时 LuCI 与 SSH 同步解除、改动前备份 PAM 与 sshd_config。
#  * 操作前必须保持一个已登录的 SSH 会话开着，再开一个新会话验证，
#    验证通过前不要关旧会话；否则一旦配错，自己也会被锁在外面。
set -eu

SECRET_FILE="/etc/totp/secret"
GA_FILE="/root/.google_authenticator"
PAM_FILE="/etc/pam.d/sshd"
SSHD_CONF="/etc/ssh/sshd_config"
BACKUP_DIR="/etc/totp/backup"

die() { echo "ERROR: $*" >&2; exit 1; }

do_sync() {
	FIRST_FACTOR="key"
	for arg in "$@"; do
		case "$arg" in
			--first-factor=key) FIRST_FACTOR="key" ;;
			--first-factor=password) FIRST_FACTOR="password" ;;
			*) die "unknown arg: $arg (use --first-factor=key|password)" ;;
		esac
	done
	[ -f "$SECRET_FILE" ] || die "no secret at $SECRET_FILE; generate one in LuCI first"
	SECRET="$(head -1 "$SECRET_FILE" | tr -d ' \t\r\n')"
	[ -n "$SECRET" ] || die "empty secret"
	# 检查依赖（缺包就停，不装生产包、不改其他配置）：
	command -v sshd >/dev/null 2>&1 || die "openssh sshd not found; opkg install openssh-server-pam google-authenticator-libpam first"
	[ -f /lib/security/pam_google_authenticator.so ] || [ -f /usr/lib/security/pam_google_authenticator.so ] \
		|| die "pam_google_authenticator.so not found; opkg install google-authenticator-libpam first"
	mkdir -p "$BACKUP_DIR"
	STAMP="$(date +%Y%m%d%H%M%S)"
	# 备份现有 PAM 与 sshd_config（若已备份过本次，不覆盖旧备份）：
	[ -f "$PAM_FILE" ] && cp -n "$PAM_FILE" "$BACKUP_DIR/sshd.pam.$STAMP.bak" || true
	[ -f "$SSHD_CONF" ] && cp -n "$SSHD_CONF" "$BACKUP_DIR/sshd_config.$STAMP.bak" || true
	# 保留已有备用码（若 google_authenticator 文件已存在，复用其中的明文备用码行；
	# 若是首次同步，备用码由 LuCI 生成时经 stdin 传入，见下）：
	EXISTING_CODES=""
	if [ -f "$GA_FILE" ]; then
		EXISTING_CODES="$(grep -E '^[0-9]{8}$' "$GA_FILE" || true)"
	fi
	{
		echo "$SECRET"
		echo '" RATE_LIMIT 3 30'
		echo '" WINDOW_SIZE 3'
		echo '" DISALLOW_REUSE'
		echo '" TOTP_AUTH'
		# 首次同步：若 stdin 不是终端且有 8 位数字行，把它们当备用码写入；
		# 平时（无 stdin 备用码）则保留已有备用码。
		if [ ! -t 0 ]; then
			while IFS= read -r line; do
				case "$line" in
					[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) echo "$line" ;;
				esac
			done
		fi
		[ -n "$EXISTING_CODES" ] && printf '%s\n' "$EXISTING_CODES"
	} > "$GA_FILE.tmp"
	chmod 600 "$GA_FILE.tmp"
	chown root:root "$GA_FILE.tmp" 2>/dev/null || true
	mv "$GA_FILE.tmp" "$GA_FILE"
	# PAM：fail-closed，不加 nullok（无密钥文件的用户直接拒绝）。
	# 注意：/etc/pam.d/sshd 在 OpenWrt 上可能不存在，首次创建即为此内容。
	cat > "$PAM_FILE" <<'EOF'
# pam.d/sshd -- luci-totp experimental (fail-closed, no nullok)
auth required pam_google_authenticator.so
account required pam_unix.so
session required pam_unix.so
EOF
	chmod 644 "$PAM_FILE"
	# sshd_config：只改三个明确项，其余原样保留；用临时文件 + 校验后替换。
	cp "$SSHD_CONF" "$SSHD_CONF.totp.tmp" 2>/dev/null || touch "$SSHD_CONF.totp.tmp"
	# 删掉旧的同名行，再追加（避免重复行导致歧义）：
	sed -i '/^ChallengeResponseAuthentication/d; /^UsePAM/d; /^AuthenticationMethods/d; /^PasswordAuthentication/d' "$SSHD_CONF.totp.tmp"
	{
		echo "ChallengeResponseAuthentication yes"
		echo "UsePAM yes"
		if [ "$FIRST_FACTOR" = "key" ]; then
			echo "AuthenticationMethods publickey,keyboard-interactive"
			echo "PasswordAuthentication no"
		else
			echo "AuthenticationMethods password,keyboard-interactive"
			echo "PasswordAuthentication yes"
		fi
	} >> "$SSHD_CONF.totp.tmp"
	sshd -t -f "$SSHD_CONF.totp.tmp" || die "sshd_config check failed; original NOT replaced"
	mv "$SSHD_CONF.totp.tmp" "$SSHD_CONF"
	echo "SYNCED: $GA_FILE (600 root), PAM + sshd_config updated (backups in $BACKUP_DIR)."
	echo "NEXT: keep your current SSH session open, open a NEW session and"
	echo "verify key (+TOTP code) login works, THEN restart sshd:"
	echo "  /etc/init.d/sshd enable; /etc/init.d/sshd start"
	echo "Dropbear must be stopped/disabled if it still binds port 22:"
	echo "  /etc/init.d/dropbear stop; /etc/init.d/dropbear disable"
	echo "WARNING: do NOT leave an alternate Dropbear port open as 'emergency'"
	echo "access -- it would bypass the TOTP gate. Use serial console as recovery."
}

do_disable() {
	# 停用：删 SSH 同步文件，恢复 PAM 与 sshd_config 备份，LuCI 侧的 enabled
	# 开关由 CBI 页负责（本脚本只管 SSH 一侧，两边都要关才算同步解除）。
	rm -f "$GA_FILE"
	latest_pam="$(ls -t "$BACKUP_DIR"/sshd.pam.*.bak 2>/dev/null | head -1 || true)"
	latest_conf="$(ls -t "$BACKUP_DIR"/sshd_config.*.bak 2>/dev/null | head -1 || true)"
	[ -n "$latest_pam" ] && cp "$latest_pam" "$PAM_FILE" || rm -f "$PAM_FILE"
	[ -n "$latest_conf" ] && cp "$latest_conf" "$SSHD_CONF" || true
	echo "DISABLED: SSH TOTP file removed, PAM/sshd_config restored from backup (if any)."
	echo "Also turn off '启用 TOTP' in LuCI, or LuCI login will still require a code."
}

case "${1:-}" in
	sync) shift; do_sync "$@" ;;
	disable) do_disable ;;
	*) echo "usage: $0 {sync [--first-factor=key|password]|disable}"; exit 1 ;;
esac
