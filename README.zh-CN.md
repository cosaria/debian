# Reinstall

[English](README.md) | [简体中文](README.zh-CN.md)

面向 VPS 和独立服务器的极简 Debian 13 网络重装脚本。

`reinstall.sh` 会准备一个 Debian Installer 启动项，注入无人值守安装所需的
preseed 配置，并让机器通过网络自动重装为 Debian。它适合已经拥有 root 权限、
但没有供应商救援 ISO 的场景。

> [!WARNING]
> 重启后这个脚本会执行破坏性操作：它会重新分区目标磁盘，并在原系统上安装
> Debian。务必先运行 `--dry-run`，确认目标磁盘、网络配置和账户配置都正确。

## 特性

- 仅支持 Debian 13 / trixie，参数面保持小而清晰。
- 自动读取当前系统的静态网络配置。
- 保留当前活跃网卡上的多个全局 IPv4 和 IPv6 地址。
- 默认使用 root 账户，也可以创建普通 sudo 用户。
- SSH 公钥既可以通过 URL 获取，也可以直接传入公钥文本。
- 内置 Google、Cloudflare 和中国大陆友好预设。
- 支持 swap 分区、自定义镜像源、代理和额外软件包。
- 单文件 POSIX shell 脚本，不需要构建步骤。

## 环境要求

- 当前系统需要 root 权限。
- 需要 GRUB 2 引导器。
- 机器需要能够启动 Debian netboot 内核，例如 KVM、云 VPS 或物理机。
- 当前系统需要已有可用的静态网络路由，脚本会复制地址、网关、DNS 和网卡信息。

容器不受支持，因为容器无法控制引导器。

## 快速开始

```sh
curl -fLO https://raw.githubusercontent.com/cosaria/debian/main/reinstall.sh && chmod +x reinstall.sh

sudo ./reinstall.sh --dry-run
sudo ./reinstall.sh
sudo reboot
```

重启后，机器会进入 Debian Installer，并自动完成 Debian 13 安装。安装完成后，
系统会重启进入新的 Debian。

普通执行会清空终端，并显示简洁的安装摘要和步骤进度。如果想查看完整 preseed
和 GRUB 启动项，请使用 `--dry-run`。

## 默认行为

| 项目 | 默认值 |
| --- | --- |
| Debian 版本 | `13` / `trixie` |
| 账户 | `root` |
| 主机名 | `linuxserver` |
| SSH 端口 | `22` |
| 网络 | 静态网络，从当前系统复制 |
| IPv4 DNS | `8.8.8.8 1.1.1.1` |
| IPv6 DNS | `2001:4860:4860::8888 2606:4700:4700::1111` |
| NTP | `time.google.com` |
| 镜像源 | `https://deb.debian.org/debian` |
| 文件系统 | `ext4` |
| Swap | 禁用 |
| 内核 | Debian 默认内核 |
| 推荐依赖 | 默认安装 |
| SSH | Debian Installer `ssh-server` 任务 |
| 额外软件包 | 无 |

如果没有提供 `--password`，脚本会交互式询问密码。

## 安装示例

使用默认配置和 root 账户：

```sh
sudo ./reinstall.sh
```

创建普通 sudo 用户：

```sh
sudo ./reinstall.sh --username debian --password 'change-me'
```

使用 SSH 公钥登录，而不是 SSH 密码登录：

```sh
sudo ./reinstall.sh \
  --authorized-key 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA...' \
  --password 'console-password'
```

使用中国大陆友好的镜像源、DNS 和 NTP：

```sh
sudo ./reinstall.sh --china --timezone Asia/Shanghai
```

添加 1 GiB swap 分区和额外软件包：

```sh
sudo ./reinstall.sh --swap 1024 --install 'curl git vim htop'
```

启用 Debian Installer SSH 控制台，用于远程调试安装过程：

```sh
sudo ./reinstall.sh \
  --network-console \
  --authorized-keys-url https://github.com/yourname.keys
```

## 参数

### 预设

| 参数 | 说明 |
| --- | --- |
| `--google` | 使用 Google DNS 和 `time.google.com`，镜像源保持默认 Debian 镜像。 |
| `--cloudflare` | 使用 Cloudflare DNS 和 `time.cloudflare.com`，镜像源保持默认 Debian 镜像。 |
| `--china` | 使用清华镜像源、中国大陆友好 DNS 和阿里云 NTP。 |

### 系统

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `--version 13` | `13` | Debian 版本。只接受 `13` 或 `trixie`。 |
| `--hostname NAME` | `linuxserver` | 安装后系统的主机名。 |
| `--timezone ZONE` | `UTC` | 时区，例如 `Asia/Shanghai`。 |
| `--dry-run` | 禁用 | 只输出生成的 preseed 和 GRUB 启动项，不执行安装准备。 |

### 账户和 SSH

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `--username USER` | `root` | `root` 表示只启用 root；其他用户名会创建普通 sudo 用户。 |
| `--password PASSWORD` | 交互询问 | root 或普通用户的密码。 |
| `--authorized-key KEY` | 空 | 向安装后的账户写入一条 SSH 公钥文本。 |
| `--authorized-keys-url URL` | 空 | 从 URL 下载 SSH 公钥，例如 `https://github.com/user.keys`。 |
| `--sudo-with-password` | 禁用 | sudo 需要输入用户密码。默认情况下 sudo 免密。 |
| `--ssh-port PORT` | `22` | 安装后系统的 SSH 端口。 |
| `--network-console` | 禁用 | 在系统安装前启用 Debian Installer 的 SSH 控制台。 |

只要使用了任意 SSH 公钥来源，安装后的系统会禁用 SSH 密码登录。密码仍会被设置，
可用于控制台登录，或在启用 `--sudo-with-password` 时用于 sudo。

`--authorized-key` 只用于安装后的系统。如果要让 Debian Installer 的
network-console 使用密钥登录，请使用 `--authorized-keys-url`。

### 网络

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `--dns 'ADDRS'` | `8.8.8.8 1.1.1.1` | IPv4 DNS 服务器。 |
| `--dns6 'ADDRS'` | `2001:4860:4860::8888 2606:4700:4700::1111` | IPv6 DNS 服务器。 |
| `--ntp HOST` | `time.google.com` | NTP 服务器。 |
| `--ethx` | 禁用 | 禁用 predictable interface names，使用 `eth0` 这类网卡名。 |

脚本会检测当前静态网络配置，并写入 preseed。当前活跃网卡上的额外全局 IPv4
和 IPv6 地址会追加到安装后系统的 `/etc/network/interfaces`。

### 镜像源和代理

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `--mirror URL` | `https://deb.debian.org/debian` | Debian 镜像源基础 URL。 |
| `--proxy URL` | 如果设置了 `$https_proxy` 则使用它 | 下载和 APT 使用的代理。 |

安全更新源会根据选择的镜像源自动派生。

### 磁盘和分区

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `--disk DEVICE` | 自动检测 | 目标磁盘，例如 `/dev/vda` 或 `/dev/nvme0n1`。 |
| `--filesystem FS` | `ext4` | 根分区文件系统。 |
| `--swap MIB` | `0` | swap 分区大小，单位 MiB。`1024` 大约创建 1 GiB swap。 |
| `--no-force-gpt` | 禁用 | 不强制使用 GPT 分区表。 |

如果机器有多块磁盘，请手动指定 `--disk`。

### 软件包

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `--install 'PKGS'` | 空 | 额外安装的软件包。重复项会自动去重。 |
| `--no-install-recommends` | 未设置 | 不安装推荐依赖。 |

脚本会选择 Debian Installer 的 `ssh-server` 任务来启用 SSH。除非使用
`--install`，否则不会安装额外软件包。

## 工作原理

1. 检测当前活跃的静态网络配置。
2. 下载 Debian netboot kernel 和 initrd 到 `/boot/debian-trixie/`。
3. 生成无人值守安装所需的 preseed 文件。
4. 将 preseed 注入安装器 initrd。
5. 通过 GRUB 添加 `reinstall` 启动项。
6. 让机器进入可重启安装状态。

重启前，脚本只会改动 `/boot/debian-trixie/` 和 GRUB 配置。真正的破坏性安装
会在启动 installer 后才开始。

## 重启前回滚

如果已经准备了安装器但还没重启，可以删除生成文件并重新生成 GRUB 配置：

```sh
sudo rm -rf /boot/debian-trixie /etc/default/grub.d/zz-reinstall.cfg
sudo update-grub || sudo grub2-mkconfig -o /boot/grub2/grub.cfg
```

## 故障排查

先检查生成配置：

```sh
sudo ./reinstall.sh --dry-run
```

指定目标磁盘前先列出磁盘：

```sh
lsblk
sudo ./reinstall.sh --disk /dev/vda
```

如果需要在安装过程中远程访问 Debian Installer，可以启用 network-console：

```sh
sudo ./reinstall.sh \
  --network-console \
  --authorized-keys-url https://github.com/yourname.keys
```

重启后连接：

```sh
ssh installer@SERVER_IP
```

## 安全提示

- 在命令行中传入 `--password` 可能会留下 shell history。交互式输入更安全。
- SSH 登录优先使用 `--authorized-key` 或 `--authorized-keys-url`。
- 重启前务必确认 `--disk`，被选中的磁盘会被重新分区。
- 第一次在新平台使用时，建议保留供应商控制台或救援方式。

## 仓库

- GitHub: [cosaria/debian](https://github.com/cosaria/debian)
- Issues: [github.com/cosaria/debian/issues](https://github.com/cosaria/debian/issues)
- 原始脚本: [reinstall.sh](https://raw.githubusercontent.com/cosaria/debian/main/reinstall.sh)
