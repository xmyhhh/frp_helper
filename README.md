# FRP Helper

这个目录是一个独立的 FRP 配置工具包，用来把内网 Linux/WSL/Windows 服务映射到公网服务器。

## FRP 是怎么工作的

家里电脑、公司内网机器、Windows 里的 WSL 通常没有公网 IP，公网用户不能直接访问它们的 `127.0.0.1:8765`、`22`、`3000` 这类端口。

FRP 的做法是让内网机器主动连出去：

```text
浏览器 / SSH 客户端
  -> 公网服务器的端口
  -> frps，运行在公网服务器
  -> 已建立的 FRP 隧道
  -> frpc，运行在内网 Linux/WSL/Windows
  -> 内网服务，例如 127.0.0.1:8765 或 127.0.0.1:22
```

也就是说：

- `frps` 放在有公网 IP 的服务器上，负责接公网流量。
- `frpc` 放在内网 Linux/WSL/Windows 里，主动连接 `frps`。
- 端口映射告诉 FRP：公网哪个端口，要转发到内网哪个端口。

例子：

```text
公网服务器IP:18080 -> WSL 127.0.0.1:8765
公网服务器IP:10022 -> WSL 127.0.0.1:22
```

所以你不需要在家里路由器做端口转发，也不需要 Nginx。只要公网服务器能被访问、WSL 能连到公网服务器，映射就能工作。

不依赖在线下载。脚本会直接使用当前目录里的 FRP 压缩包：

```text
frp_*_linux_<arch>.tar.gz
frp_*_windows_<arch>.zip
```

注意：压缩包架构必须和运行脚本的机器匹配。脚本会按 `uname -m` 自动选择当前目录里的匹配包。

常见匹配关系：

```text
x86_64 / amd64   -> frp_*_linux_amd64.tar.gz
aarch64 / arm64  -> frp_*_linux_arm64.tar.gz
armv7l / armv7   -> frp_*_linux_arm.tar.gz, frp_*_linux_armv7.tar.gz, or frp_*_linux_armhf.tar.gz
mips64           -> frp_*_linux_mips64.tar.gz
```

当前目录已经放了：

```text
frp_0.69.1_linux_amd64.tar.gz
frp_0.69.1_linux_arm64.tar.gz
frp_0.69.1_linux_mips64.tar.gz
```

普通 WSL 和大多数云服务器通常会自动选 `linux_amd64`。

如果要在 Windows 原生运行 `frpc`，还需要放 Windows 版压缩包，例如：

```text
frp_0.69.1_windows_amd64.zip
```

## 文件

```text
configure-public-frps.sh  # 公网 Linux server 端，配置 frps
configure-local-frpc.sh   # 内网 Linux/WSL local 端，配置 frpc
configure-windows-frpc.ps1 # 内网 Windows local 端，配置 frpc 和计划任务
server_status.sh          # 公网 Linux server 端，查看 frps 状态
client_status.sh          # 内网 Linux/WSL local 端，查看 frpc 状态
windows_client_status.ps1 # 内网 Windows local 端，查看 frpc 状态
server_stop.sh            # 公网 Linux server 端，停止 frps
client_stop.sh            # 内网 Linux/WSL local 端，停止 frpc
windows_client_stop.ps1   # 内网 Windows local 端，停止 frpc
```

## 典型映射

```text
http://公网服务器IP:18080 -> WSL 127.0.0.1:8765
ssh -p 10022 user@公网服务器IP -> WSL 127.0.0.1:22
```

以后可以继续加：

```text
公网服务器IP:13000 -> WSL 127.0.0.1:3000
公网服务器IP:15432 -> WSL 127.0.0.1:5432
```

## 1. 公网服务器配置 server 端

把本目录放到公网 Linux 服务器上，并确保里面有匹配服务器架构的 FRP 压缩包。

运行向导：

```bash
cd frp_helper
sudo bash configure-public-frps.sh
```

向导会询问：

- FRP control port，默认 `7000`
- FRP token
- 要开放的公网服务端口，默认 `18080,10022`

脚本会：

- 从本地压缩包安装 `frps` 到 `/opt/frp/frps`
- 写入 `/etc/frp/frps.toml`
- 创建并启动 `frps.service`
- 尝试使用 `ufw` 放行端口
- 提醒你在云厂商安全组里放行端口

也可以非交互执行：

```bash
sudo bash configure-public-frps.sh \
  --token replace-with-a-strong-token \
  --server-port 7000 \
  --allow-port 18080 \
  --allow-port 10022 \
  --yes
```

## 2. WSL / 内网 Linux 配置 local 端

在 WSL 中进入本目录，并确保里面有匹配 WSL 架构的 FRP 压缩包。

运行向导：

```bash
cd /mnt/f/codex_prj/frp_helper
sudo bash configure-local-frpc.sh
```

向导会询问：

- 公网服务器 IP 或域名
- FRP control port，默认 `7000`
- FRP token，必须和 server 端一致
- 是否添加默认 Viewer 映射：`8765 -> 18080`
- 是否添加默认 SSH 映射：`22 -> 10022`
- 是否继续添加更多端口映射

脚本会：

- 从本地压缩包安装 `frpc` 到 `/opt/frp/frpc`
- 写入 `/etc/frp/frpc.toml`
- 创建并启动 `frpc.service`
- 如果 WSL 没有 systemd，会提示手动启动命令

也可以非交互执行：

```bash
sudo bash configure-local-frpc.sh \
  --server-addr 公网服务器IP \
  --token replace-with-a-strong-token \
  --server-port 7000 \
  --map viewer:8765:18080 \
  --map ssh:22:10022 \
  --yes
```

## 3. 添加更多端口

## 3. Windows 原生配置 local 端

如果不想用 WSL，也可以直接在 Windows 上运行 `frpc`。

先把 Windows 版 FRP 压缩包放进本目录，例如：

```text
frp_0.69.1_windows_amd64.zip
```

用管理员 PowerShell 运行向导：

```powershell
cd F:\codex_prj\frp_helper
.\configure-windows-frpc.ps1
```

脚本会：

- 从本地 Windows 版 FRP zip 解压 `frpc.exe`
- 安装到 `C:\frp`
- 生成 `C:\frp\frpc.toml`
- 创建 Windows 计划任务 `frpc`
- 设置开机自动启动，并立即启动

也可以非交互执行：

```powershell
.\configure-windows-frpc.ps1 `
  -ServerAddr 公网服务器IP `
  -Token replace-with-a-strong-token `
  -ServerPort 7000 `
  -Map viewer:8765:18080 `
  -Map rdp:3389:13389 `
  -Yes
```

查看 Windows local 端状态：

```powershell
.\windows_client_status.ps1
```

停止 Windows local 端：

```powershell
.\windows_client_stop.ps1
```

如果也要取消开机自启：

```powershell
.\windows_client_stop.ps1 -Disable
```

## 4. 添加更多端口

映射格式：

```text
name:local_port:remote_port[:local_ip]
```

例子：

```text
viewer:8765:18080
ssh:22:10022
api:3000:13000
postgres:5432:15432:127.0.0.1
```

如果新增 `api:3000:13000`：

公网 server 端重新运行：

```bash
sudo bash configure-public-frps.sh \
  --token replace-with-a-strong-token \
  --server-port 7000 \
  --allow-port 18080 \
  --allow-port 10022 \
  --allow-port 13000 \
  --yes
```

WSL local 端重新运行：

```bash
sudo bash configure-local-frpc.sh \
  --server-addr 公网服务器IP \
  --token replace-with-a-strong-token \
  --server-port 7000 \
  --map viewer:8765:18080 \
  --map ssh:22:10022 \
  --map api:3000:13000 \
  --yes
```

## 5. 检查服务

公网 server：

```bash
sudo systemctl status frps --no-pager
sudo journalctl -u frps -f
sudo bash server_status.sh /etc/frp/frps.toml 18080 10022
```

WSL local：

```bash
sudo systemctl status frpc --no-pager
sudo journalctl -u frpc -f
sudo bash client_status.sh
```

Windows local：

```powershell
.\windows_client_status.ps1
```

如果 WSL 没有 systemd：

```bash
sudo /opt/frp/frpc -c /etc/frp/frpc.toml
```

## 6. 停止服务

公网 server 端停止 `frps`：

```bash
sudo bash server_stop.sh
```

WSL local 端停止 `frpc`：

```bash
sudo bash client_stop.sh
```

Windows local 端停止 `frpc`：

```powershell
.\windows_client_stop.ps1
```

默认只是停止当前服务，开机自启状态不变。如果也要取消开机自启：

```bash
sudo bash server_stop.sh --disable
sudo bash client_stop.sh --disable
.\windows_client_stop.ps1 -Disable
```

## 7. 常见问题

- `no matching FRP archive found`：当前目录没有匹配架构的压缩包。普通 WSL 通常需要 `linux_amd64`，树莓派/ARM 服务器通常需要 `linux_arm64` 或 `linux_arm`。
- 公网访问不通：检查云厂商安全组是否放行 `remotePort`。
- `frpc` 连不上：检查公网 IP、`serverPort`、token 是否一致。
- SSH 连不上：确认 WSL 内已安装并启动 `openssh-server`。
- 公网 server 端使用 `--allow-port 10022` 只负责放行端口；真正的 SSH 映射要在 local 端配置 `--map ssh:22:10022`，并且 WSL 的 `127.0.0.1:22` 必须能连通。
