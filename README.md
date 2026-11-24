# server-bootstrap

新服务器一键初始化：加 SSH 公钥 + 进 Tailscale，一条命令搞定。

## 一行命令

在新服务器上（root 身份）跑：

```bash
curl -fsSL https://raw.githubusercontent.com/Anti2077/server-bootstrap/main/new-server-bootstrap.sh | sudo TS_AUTHKEY='tskey-auth-xxx' TS_HOSTNAME='m-ui-slave-hk' bash
```

- `TS_AUTHKEY`：去 Tailscale Admin → Settings → Keys → Generate auth key 生成，别写死进脚本，别截图外发，泄露就去后台 Revoke 重生成。
- `TS_HOSTNAME`：可选，机器在 Tailscale 里显示的名字。
- 没给 Auth Key 也能跑，会走交互式登录，按提示打开链接授权。

## 脚本会做什么

- 把常用 SSH 公钥写进 `/root/.ssh/authorized_keys`（幂等，重复跑不重复加）
  - `anti_macbook_m4`
  - `bb-2077@anti2077-openclaw`
  - `everest`
- 装 Tailscale（已装就跳过），`tailscale up --ssh` 进 tailnet
- 可选 `--harden`：ufw + fail2ban；可选 `--disable-password-auth`：关 SSH 密码登录（先确认密钥能登再用）

## 安全说明

脚本里只有公钥，没有私钥、没有 Auth Key、没有服务器 IP。
公钥本来就是公开的，知道公钥也登不进来，登录要的是你手里的私钥。

跑之前建议先下载下来看一眼，锁死到某个 commit / tag 再跑，别盲跑 `main`。
