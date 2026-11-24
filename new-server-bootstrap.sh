#!/usr/bin/env bash
# 新服务器一键初始化：加 SSH 公钥 + 进 Tailscale
# 用法（在新机上，root 身份跑一条就行）：
#   curl -fsSL <你的脚本地址> -o bootstrap.sh
#   sudo TS_AUTHKEY='tskey-auth-xxx' TS_HOSTNAME='m-ui-slave-hk' bash bootstrap.sh
#
# 不想把 key 写在命令行历史里，也可以先 export 再跑：
#   export TS_AUTHKEY='tskey-auth-xxx'
#   sudo -E bash bootstrap.sh --hostname m-ui-slave-hk
#
# 没有 auth key 也可以跑：脚本会装好 Tailscale，然后走交互式登录
#   sudo bash bootstrap.sh
#   sudo tailscale up   # 按提示打开链接授权
#
# Auth key 去哪拿：Tailscale Admin -> Settings -> Keys -> Generate auth key
#   建议勾：Reusable（可复用，加多台不用每次生成）、Tag 选 tag:server
#   有效期只管这张“入场券”能不能再加新机，已加进来的不受影响。
#   千万别把 key 写死进脚本、发群里、截图外发，泄露就去后台 Revoke 重生成。
#
# 公钥说明：下面 KEYS 里已经内置了你 2026-11-24 给的 3 把常用公钥：
#   anti_macbook_m4 / bb-2077@anti2077-openclaw / everest。
#   以后要加新钥匙，直接往 KEYS 里加一行，或跑的时候用
#   --extra-keys-file 指向一个每行一把公钥的文件。
set -euo pipefail

# ---------------- 可改配置：经常用的公钥，一行一把 ----------------
KEYS=(
  # 用户 2026-11-24 提供的常用公钥（3 把）
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAKaTPDq09mQC0aXZ/XxwigX18FrAa3AXJVOBqOVqar5 anti_macbook_m4"
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINnLiPzqwr3myFfA3u/PjQtUeD89OaIg01nsNE6RKz7X bb-2077@anti2077-openclaw"
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG4fxSdD8r7nqSLp+X9CfNi4mXPHJkElO3DCerp/LKJA everest"
)
# -------------------------------------------------------------------

TS_AUTHKEY="${TS_AUTHKEY:-}"
TS_HOSTNAME="${TS_HOSTNAME:-}"
EXTRA_KEYS_FILE="${EXTRA_KEYS_FILE:-}"
DISABLE_PASSWORD_AUTH=0
ENABLE_TAILSCALE_SSH=1
HARDEN=0

usage() {
  cat <<'EOF'
用法: sudo bash new-server-bootstrap.sh [选项]
  --auth-key KEY           Tailscale auth key（也可传环境变量 TS_AUTHKEY）
  --hostname NAME          机器在 Tailscale 里显示的名字，如 m-ui-slave-hk
  --extra-keys-file FILE   额外公钥文件，每行一把
  --no-tailscale-ssh       不开 Tailscale SSH（默认开，见下）
  --harden                 顺手加固：ufw 只放 SSH + 装 fail2ban（不关密码登录）
  --disable-password-auth  关掉 SSH 密码登录（危险选项：先在新窗口确认密钥能登再用）
  -h, --help               看这个帮助
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --auth-key) TS_AUTHKEY="$2"; shift 2 ;;
    --hostname) TS_HOSTNAME="$2"; shift 2 ;;
    --extra-keys-file) EXTRA_KEYS_FILE="$2"; shift 2 ;;
    --no-tailscale-ssh) ENABLE_TAILSCALE_SSH=0; shift ;;
    --harden) HARDEN=1; shift ;;
    --disable-password-auth) DISABLE_PASSWORD_AUTH=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "请用 root / sudo 跑这个脚本" >&2; exit 1
fi

# 等 unattended-upgrades 占的 dpkg 锁放开（新机刚开机经常在后台更新，别硬删 lock）
for _ in $(seq 1 30); do
  if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then break; fi
  echo "等 dpkg 锁释放（后台更新中）..."; sleep 10
done

# 1. 加 SSH 公钥（幂等：重复跑不会重复加）
add_keys_to() {
  local home_dir="$1"
  local ssh_dir="$home_dir/.ssh"
  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir"
  touch "$ssh_dir/authorized_keys"
  chmod 600 "$ssh_dir/authorized_keys"
  local key
  for key in "${KEYS[@]}"; do
    [ -n "$key" ] || continue
    grep -qxF "$key" "$ssh_dir/authorized_keys" 2>/dev/null || echo "$key" >> "$ssh_dir/authorized_keys"
  done
  if [ -n "$EXTRA_KEYS_FILE" ]; then
    while IFS= read -r key || [ -n "$key" ]; do
      [ -n "$key" ] || continue
      case "$key" in \#*) continue;; esac
      grep -qxF "$key" "$ssh_dir/authorized_keys" 2>/dev/null || echo "$key" >> "$ssh_dir/authorized_keys"
    done < "$EXTRA_KEYS_FILE"
  fi
  chown -R "$(stat -c '%U:%G' "$home_dir")" "$ssh_dir" 2>/dev/null || true
  chmod 700 "$ssh_dir"; chmod 600 "$ssh_dir/authorized_keys"
}

add_keys_to /root
# 有普通用户也顺手加一份（Ubuntu 默认 ubuntu，Debian 常没有，存在才加）
for u in ubuntu debian admin; do
  if id "$u" >/dev/null 2>&1; then add_keys_to "$(eval echo "~$u")"; fi
done
echo "✓ SSH 公钥已写入 /root/.ssh/authorized_keys"

# 2. 改主机名（可选）
if [ -n "$TS_HOSTNAME" ]; then
  hostnamectl set-hostname "$TS_HOSTNAME" || true
  echo "✓ 主机名: $TS_HOSTNAME"
fi

# 3. 装 Tailscale（已装就跳过）
if ! command -v tailscale >/dev/null 2>&1; then
  echo "装 Tailscale..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq && apt-get install -y -qq curl ca-certificates gnupg >/dev/null
  curl -fsSL https://tailscale.com/install.sh | sh
else
  echo "✓ Tailscale 已安装: $(tailscale version 2>/dev/null | head -n1)"
fi

# 4. 进 Tailscale
if tailscale status >/dev/null 2>&1 && tailscale ip -4 >/dev/null 2>&1; then
  echo "✓ 已在 Tailscale 里: $(tailscale ip -4 2>/dev/null | head -n1)"
else
  UP_ARGS=()
  [ -n "$TS_AUTHKEY" ] && UP_ARGS+=(--auth-key="$TS_AUTHKEY")
  [ -n "$TS_HOSTNAME" ] && UP_ARGS+=(--hostname="$TS_HOSTNAME")
  [ "$ENABLE_TAILSCALE_SSH" = 1 ] && UP_ARGS+=(--ssh)
  echo "tailscale up ${UP_ARGS[*]@Q} ..."
  if [ -n "$TS_AUTHKEY" ]; then
    tailscale up "${UP_ARGS[@]}"
  else
    echo "没给 auth key，改交互式登录：按提示打开链接授权即可。"
    tailscale up "${UP_ARGS[@]}"
  fi
  echo "✓ Tailscale IP: $(tailscale ip -4 | head -n1)"
fi

# 5. 可选加固（默认不做，不关密码登录）
if [ "$HARDEN" = 1 ]; then
  apt-get install -y -qq ufw fail2ban >/dev/null
  ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null 2>&1
  ufw --force enable >/dev/null 2>&1 || true
  systemctl enable --now fail2ban >/dev/null 2>&1 || true
  echo "✓ ufw + fail2ban 已开"
fi

if [ "$DISABLE_PASSWORD_AUTH" = 1 ]; then
  echo "⚠ 你选了关密码登录：请先另开一个窗口确认密钥能登录，再跑这一步，别把自己锁外面。"
  cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)
  sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
  grep -q '^PasswordAuthentication' /etc/ssh/sshd_config || echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config
  systemctl reload sshd || systemctl reload ssh || true
  echo "✓ SSH 密码登录已关（备份在 /etc/ssh/sshd_config.bak.*）"
fi

echo
echo "完成。验证一下："
echo "  tailscale status | head"
echo "  tailscale ip -4"
echo "  另开窗口 ssh -i ~/.ssh/id_ed25519 root@<Tailscale IP>  # 确认密钥能登"
echo "服务器想长期在线，记得去 Tailscale 后台把这台的 Key expiry 关掉（默认 180 天过期会掉线）。"
