# FRP Helper

这个目录是一个独立的 FRP 配置工具包，用来把内网 Linux/WSL 服务映射到公网服务器。

不依赖在线下载。脚本会直接使用当前目录里的 FRP 压缩包：

```text
frp_*_linux_<arch>.tar.gz
```

注意：压缩包架构必须和运行脚本的机器匹配。常见 WSL/云服务器一般是 `linux_amd64`，例如：

```text
frp_0.69.1_linux_amd64.tar.gz
```

如果当前目录只有 `frp_0.69.1_linux_mips64.tar.gz`，它只能用于 `mips64` Linux，不能用于普通 x86_64/amd64 WSL 或云服务器。

## 文件

```text
configure-public-frps.sh  # 公网 Linux server 端，配置 frps
configure-local-frpc.sh   # 内网 Linux/WSL local 端，配置 frpc
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

## 4. 检查服务

公网 server：

```bash
sudo systemctl status frps --no-pager
sudo journalctl -u frps -f
```

WSL local：

```bash
sudo systemctl status frpc --no-pager
sudo journalctl -u frpc -f
```

如果 WSL 没有 systemd：

```bash
sudo /opt/frp/frpc -c /etc/frp/frpc.toml
```

## 5. 常见问题

- `no matching FRP archive found`：当前目录没有匹配架构的压缩包。普通 WSL 通常需要 `linux_amd64`。
- 公网访问不通：检查云厂商安全组是否放行 `remotePort`。
- `frpc` 连不上：检查公网 IP、`serverPort`、token 是否一致。
- SSH 连不上：确认 WSL 内已安装并启动 `openssh-server`。

