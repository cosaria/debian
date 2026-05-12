# Reinstall

[English](README.md) | [简体中文](README.zh-CN.md)

Minimal Debian 13 network reinstall script for VPS and dedicated servers.

`reinstall.sh` prepares a Debian Installer boot entry, injects an unattended
preseed configuration, and lets the machine reinstall itself from the network.
It is designed for clean Debian installs on machines where you already have
root access but do not have a provider rescue ISO.

> [!WARNING]
> This script is destructive after reboot. It repartitions the target disk and
> installs Debian over the existing system. Always run `--dry-run` first and
> verify the target disk, network configuration, and account settings.

## Highlights

- Debian 13 / trixie only, with a small and predictable option surface.
- Static network configuration is detected from the current system.
- Multiple global IPv4 and IPv6 addresses on the active interface are preserved.
- Root login is the default, with optional sudo user creation.
- SSH public keys can be provided by URL or as a direct key string.
- Google, Cloudflare, and China-friendly presets are built in.
- Optional swap partition, custom mirror, proxy, and extra packages.
- Single POSIX shell script; no project build step.

## Requirements

- Root access on the current system.
- GRUB 2 bootloader.
- A KVM, cloud VPS, or physical machine that can boot the Debian netboot kernel.
- A currently working static network route so the script can copy the address,
  gateway, DNS, and interface details.

Containers are not supported because they do not control the bootloader.

## Quick Start

```sh
curl -fLO https://raw.githubusercontent.com/cosaria/debian/main/reinstall.sh && chmod +x reinstall.sh

sudo ./reinstall.sh --dry-run
sudo ./reinstall.sh
sudo reboot
```

After reboot, the machine boots into Debian Installer and performs an unattended
Debian 13 installation. When installation finishes, it reboots into the new
system.

Normal execution clears the terminal and shows a concise install summary plus
short progress steps. Use `--dry-run` when you want to inspect the full preseed
and GRUB entry.

## Default Behavior

| Item | Default |
| --- | --- |
| Debian version | `13` / `trixie` |
| Account | `root` |
| Hostname | `linuxserver` |
| SSH port | `22` |
| Network | Static, copied from the current system |
| IPv4 DNS | `8.8.8.8 1.1.1.1` |
| IPv6 DNS | `2001:4860:4860::8888 2606:4700:4700::1111` |
| NTP | `time.google.com` |
| Mirror | `https://deb.debian.org/debian` |
| Filesystem | `ext4` |
| Swap | Disabled |
| Kernel | Debian default kernel |
| Recommended packages | Enabled |
| SSH | Debian Installer `ssh-server` task |
| Extra packages | None |

If `--password` is not provided, the script asks for one interactively.

## Installation Examples

Root account with the default settings:

```sh
sudo ./reinstall.sh
```

Create a regular sudo user:

```sh
sudo ./reinstall.sh --username debian --password 'change-me'
```

Use SSH keys instead of SSH password login:

```sh
sudo ./reinstall.sh \
  --authorized-key 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA...' \
  --password 'console-password'
```

China-friendly mirror, DNS, NTP, and timezone:

```sh
sudo ./reinstall.sh --china
```

Add a 1 GiB swap partition and extra packages:

```sh
sudo ./reinstall.sh --swap 1024 --install 'curl git vim htop'
```

Enable the Debian Installer SSH console for remote debugging:

```sh
sudo ./reinstall.sh \
  --network-console \
  --authorized-keys-url https://github.com/yourname.keys
```

## Options

### Presets

| Option | Description |
| --- | --- |
| `--google` | Use Google DNS and `time.google.com` with the default Debian mirror. |
| `--cloudflare` | Use Cloudflare DNS and `time.cloudflare.com` with the default Debian mirror. |
| `--china` | Use Tsinghua mirror, China-friendly DNS, Aliyun NTP, and `Asia/Shanghai` timezone. |

### System

| Option | Default | Description |
| --- | --- | --- |
| `--version 13` | `13` | Debian version. Only `13` or `trixie` is accepted. |
| `--hostname NAME` | `linuxserver` | Hostname for the installed system. |
| `--timezone ZONE` | `UTC` | Time zone, for example `Asia/Shanghai`. |
| `--dry-run` | Disabled | Print the generated preseed and GRUB entry without installing. |

### Account and SSH

| Option | Default | Description |
| --- | --- | --- |
| `--username USER` | `root` | `root` keeps root-only mode. Any other name creates a sudo user. |
| `--password PASSWORD` | Prompt | Password for root or the created user. |
| `--authorized-key KEY` | Empty | Add one literal SSH public key to the installed account. |
| `--authorized-keys-url URL` | Empty | Download SSH public keys from a URL, such as `https://github.com/user.keys`. |
| `--sudo-with-password` | Disabled | Require the user password for sudo. Without this, sudo is passwordless. |
| `--ssh-port PORT` | `22` | SSH port for the installed system. |
| `--network-console` | Disabled | Enable SSH access to Debian Installer before the OS is installed. |

When any authorized key source is used, SSH password authentication is disabled
in the installed system. The password is still configured for console login and
for sudo when `--sudo-with-password` is used.

`--authorized-key` is for the installed system. For key-based access to the
Debian Installer network console, use `--authorized-keys-url`.

### Network

| Option | Default | Description |
| --- | --- | --- |
| `--dns 'ADDRS'` | `8.8.8.8 1.1.1.1` | IPv4 DNS servers. |
| `--dns6 'ADDRS'` | `2001:4860:4860::8888 2606:4700:4700::1111` | IPv6 DNS servers. |
| `--ntp HOST` | `time.google.com` | NTP server for Debian Installer and the installed system's chrony service. |
| `--ethx` | Disabled | Disable predictable interface names and use names like `eth0`. |

The script detects the current static network configuration and writes it into
preseed. Extra global IPv4 and IPv6 addresses on the active interface are
appended to the installed system's `/etc/network/interfaces`.

The installed system includes chrony by default. The script writes the selected
`--ntp` host as chrony's first-boot source and enables the chrony service so the
clock is corrected before normal package operations.

### Mirror and Proxy

| Option | Default | Description |
| --- | --- | --- |
| `--mirror URL` | `https://deb.debian.org/debian` | Debian mirror base URL. |
| `--proxy URL` | `$https_proxy` if set | Proxy used for downloads and APT. |

The security repository is derived automatically from the selected mirror.

### Storage

| Option | Default | Description |
| --- | --- | --- |
| `--disk DEVICE` | Auto-detect | Target disk, for example `/dev/vda` or `/dev/nvme0n1`. |
| `--filesystem FS` | `ext4` | Root filesystem type. |
| `--swap MIB` | `0` | Swap partition size in MiB. `1024` creates about 1 GiB of swap. |
| `--no-force-gpt` | Disabled | Do not force a GPT partition table. |

Specify `--disk` manually on machines with more than one disk.

### Packages

| Option | Default | Description |
| --- | --- | --- |
| `--install 'PKGS'` | Empty | Additional packages to install. Duplicates are removed. |
| `--no-install-recommends` | Not set | Do not install recommended dependencies. |

The Debian Installer `ssh-server` task is selected for SSH access. No extra
packages are installed unless `--install` is provided.

## How It Works

1. Detects the active static network configuration.
2. Downloads the Debian netboot kernel and initrd into `/boot/debian-trixie/`.
3. Generates a preseed file for unattended Debian Installer setup.
4. Injects the preseed into the installer initrd.
5. Adds a `reinstall` boot entry through GRUB.
6. Leaves the machine ready for reboot.

Before reboot, the changes are limited to `/boot/debian-trixie/` and GRUB
configuration. The destructive installation starts only after booting the
installer entry.

## Revert Before Reboot

If you prepared the installer but changed your mind, remove the generated files
and rebuild GRUB:

```sh
sudo rm -rf /boot/debian-trixie /etc/default/grub.d/zz-reinstall.cfg
sudo update-grub || sudo grub2-mkconfig -o /boot/grub2/grub.cfg
```

## Troubleshooting

Check the generated configuration first:

```sh
sudo ./reinstall.sh --dry-run
```

List disks before choosing a target:

```sh
lsblk
sudo ./reinstall.sh --disk /dev/vda
```

Use the Debian Installer network console when you need remote access during the
installation:

```sh
sudo ./reinstall.sh \
  --network-console \
  --authorized-keys-url https://github.com/yourname.keys
```

After reboot, connect with:

```sh
ssh installer@SERVER_IP
```

## Security Notes

- Passing `--password` on the command line can expose it in shell history.
  Interactive password entry is safer.
- Prefer `--authorized-key` or `--authorized-keys-url` for SSH access.
- Verify `--disk` before rebooting; the selected disk is repartitioned.
- Keep a provider console or rescue method available for the first run on a new
  platform.

## Repository

- GitHub: [cosaria/debian](https://github.com/cosaria/debian)
- Issues: [github.com/cosaria/debian/issues](https://github.com/cosaria/debian/issues)
- Raw script: [reinstall.sh](https://raw.githubusercontent.com/cosaria/debian/main/reinstall.sh)
