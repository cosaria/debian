#!/bin/sh
# shellcheck shell=dash

set -eu

die() {
    printf "\nError: %s.\n" "$1" 1>&2
    exit 1
}

warn() {
    printf "\nWarning: %s.\nContinuing with the default...\n" "$1" 1>&2
    sleep 5
}

has_cmd() {
    command -v "$1" > /dev/null 2>&1
}

sh_quote() {
    printf "'"
    printf '%s' "$1" | sed "s/'/'\\\\''/g"
    printf "'"
}

is_uint() {
    case $1 in
        ''|*[!0-9]*)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

validate_port() {
    is_uint "$ssh_port" || die '--ssh-port must be a number from 1 to 65535'
    [ "${#ssh_port}" -le 5 ] || die '--ssh-port must be a number from 1 to 65535'
    [ "$ssh_port" -ge 1 ] && [ "$ssh_port" -le 65535 ] ||
        die '--ssh-port must be a number from 1 to 65535'
}

validate_username() {
    [ -n "$username" ] || die '"--username" must not be empty'
    [ "$username" = root ] && return

    case $username in
        [abcdefghijklmnopqrstuvwxyz]*)
            ;;
        *)
            die '"--username" must start with a lowercase letter'
            ;;
    esac

    case $username in
        *[!abcdefghijklmnopqrstuvwxyz0123456789-]*)
            die '"--username" may only contain lowercase letters, digits, and hyphens'
            ;;
    esac

    [ "${#username}" -le 32 ] || die '"--username" must be 32 characters or shorter'
}

first_network_address() {
    printf '%s\n' "$1" | awk 'NF {print; exit}'
}

count_network_addresses() {
    printf '%s\n' "$1" | awk 'NF {count++} END {print count + 0}'
}

detect_primary_network() {
    local _cidr=
    local _interface=
    local _interface6=

    auto_static_network=true
    ip=$(ip -4 r get 1.1.1.1 2> /dev/null | awk '/src/ {print $7}')
    gateway=$(ip -4 r get 1.1.1.1 2> /dev/null | awk '/via/ {print $3}')
    if [ -n "$ip" ]; then
        _cidr=$(ip -o -f inet addr show | grep -w "$ip" | awk '{print $4}' | cut -d'/' -f2)
        ip="$ip/$_cidr"
    fi

    _interface=$(ip -4 r get 1.1.1.1 2> /dev/null | awk '/dev/ {print $5}')
    [ -n "$_interface" ] && interface=$_interface
    if [ -n "$interface" ]; then
        ip4_addrs=$(ip -o -f inet addr show dev "$interface" scope global 2> /dev/null | awk '{print $4}' | awk 'NF && !seen[$0]++')
        [ -z "$ip" ] && ip=$(first_network_address "$ip4_addrs")
    fi

    _interface6=$(ip -6 route show default 2> /dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
    if [ -n "$_interface6" ]; then
        interface6=$_interface6
    elif [ -z "$interface6" ]; then
        interface6=$interface
    fi
    if [ -n "$interface6" ]; then
        ip6_addrs=$(ip -o -f inet6 addr show dev "$interface6" scope global 2> /dev/null | awk '{print $4}' | awk 'NF && !seen[$0]++')
        ip6=$(first_network_address "$ip6_addrs")
        gateway6=$(ip -6 route show default dev "$interface6" 2> /dev/null | awk '/via/ {print $3; exit}')
    fi
}

detect_disk() {
    local boot_device=
    local parent_disk=

    [ -n "$disk" ] && return 0
    has_cmd lsblk || return 0

    boot_device=$(df /boot 2> /dev/null | awk 'NR == 2 {print $1}' | grep -Eo '/dev/[a-z0-9]+' || true)
    [ -n "$boot_device" ] || return 0

    parent_disk=$(lsblk -no PKNAME "$boot_device" 2> /dev/null || true)
    [ -n "$parent_disk" ] || return 0

    disk="/dev/$parent_disk"
}

detect_arch() {
    if [ -n "$architecture" ]; then
        return 0
    fi

    {
        architecture=$(dpkg --print-architecture 2> /dev/null) || {
            case $(uname -m) in
                x86_64)
                    architecture=amd64
                    ;;
                aarch64|arm64)
                    architecture=arm64
                    ;;
                i386)
                    architecture=i386
                    ;;
                *)
                    die 'Cannot detect target architecture'
            esac
        }
    }

    return 0
}

target_script_body=
target_script_add() {
    local command=

    shift

    for argument in "$@"; do
        if [ -z "$command" ]; then
            command=$argument
        else
            command="$command $argument"
        fi
    done

    if [ -n "$command" ]; then
        target_script_body="${target_script_body}${command}
"
    fi

    return 0
}

append_plan_package() {
    local package=

    for package in "$@"; do
        case " $install " in
            *" $package "*)
                ;;
            *)
                install="${install:+$install }$package"
                ;;
        esac
    done
}

append_plan_package_list() {
    local package=

    for package in $1; do
        append_plan_package "$package"
    done
}

configure_sshd() {
    [ -z "${sshd_config_backup+1s}" ] && target_script_add 'backup /etc/ssh/sshd_config' 'if [ ! -e "/etc/ssh/sshd_config.backup" ]; then cp "/etc/ssh/sshd_config" "/etc/ssh/sshd_config.backup"; fi'
    sshd_config_backup=
    target_script_add "set sshd $1" sed -Ei \""s/^#?$1 .+/$1 $2/"\" /etc/ssh/sshd_config
}

configure_chrony() {
    append_plan_package chrony

    target_script_add 'create chrony sources directory' 'mkdir -p /etc/chrony/sources.d'
    target_script_add 'ensure chrony reads sources directory' "grep -Eq '^sourcedir[[:space:]]+/etc/chrony/sources.d' /etc/chrony/chrony.conf || printf '%s\n' 'sourcedir /etc/chrony/sources.d' >> /etc/chrony/chrony.conf"
    target_script_add 'disable default chrony sources' "sed -Ei 's/^([[:space:]]*)(pool|server|peer)[[:space:]]+/# disabled by reinstall.sh: &/' /etc/chrony/chrony.conf"
    target_script_add 'write chrony reinstall source' "printf '%s\n' $(sh_quote "server $ntp iburst") > /etc/chrony/sources.d/reinstall-ntp.sources"
    target_script_add 'ensure chrony can step clock on first boot' "grep -Eq '^makestep[[:space:]]+' /etc/chrony/chrony.conf || printf '%s\n' 'makestep 1.0 3' >> /etc/chrony/chrony.conf"
    target_script_add 'enable chrony service' 'systemctl enable chrony >/dev/null 2>&1 || true'
}

prompt_password_if_needed() {
    local prompt=

    [ -n "$password" ] && return

    if [ $# -gt 0 ]; then
        prompt=$1
    elif [ "$username" = root ]; then
        prompt="Choose a password for the root user: "
    else
        prompt="Choose a password for user $username: "
    fi

    stty -echo
    trap 'stty echo' EXIT

    while [ -z "$password" ]; do
        echo -n "$prompt" > /dev/tty
        read -r password < /dev/tty
        echo > /dev/tty
    done

    stty echo
    trap - EXIT
}

fetch_file() {
    # Set "$http/https/ftp_proxy" with "$proxy"
    # only when none of those have ever been set
    [ -n "$proxy" ] &&
    [ -z "${http_proxy+1s}" ] &&
    [ -z "${https_proxy+1s}" ] &&
    [ -z "${ftp_proxy+1s}" ] &&
    export http_proxy="$proxy" &&
    export https_proxy="$proxy" &&
    export ftp_proxy="$proxy"

    if has_cmd wget; then
        wget -q -O "$2" "$1"
    elif has_cmd curl; then
        curl -fsL "$1" -o "$2"
    elif has_cmd busybox && busybox wget --help > /dev/null 2>&1; then
        busybox wget -O "$2" "$1"
    else
        die 'Cannot find "wget", "curl" or "busybox wget" to download files'
    fi
}

run_logged() {
    local message=

    message=$1
    shift

    printf '  - %s... ' "$message"
    if "$@" >> "$log_file" 2>&1; then
        printf 'done\n'
    else
        printf 'failed\n' 1>&2
        printf 'Log: %s\n' "$log_file" 1>&2
        exit 1
    fi
}

clear_screen() {
    [ -t 1 ] || return 0
    if has_cmd clear; then
        clear 2> /dev/null || printf '\033[H\033[J'
    else
        printf '\033[H\033[J'
    fi
}

ps_raw() {
    if [ "$dry_run" = true ]; then
        cat
    else
        cat >> preseed.cfg
    fi
}

ps_comment() {
    printf '\n# %s\n\n' "$1" | ps_raw
}

ps_set() {
    printf 'd-i %s %s %s\n' "$1" "$2" "$3" | ps_raw
}

save_grub_cfg() {
    if [ "$dry_run" = true ]; then
        cat
    else
        cat >> "$grub_cfg"
    fi
}

print_install_summary() {
    local auth=
    local sudo_mode=
    local swap_summary=
    local proxy_summary=
    local gpt_summary=

    auth=password
    [ "$has_authorized_keys" = true ] && auth=ssh-key

    sudo_mode='not applicable'
    if [ "$username" != root ]; then
        sudo_mode=passwordless
        [ "$sudo_with_password" = true ] && sudo_mode='requires password'
    fi

    swap_summary=disabled
    [ "$swap_size" -gt 0 ] && swap_summary="$swap_size MiB"

    proxy_summary=none
    [ -n "$proxy" ] && proxy_summary=$proxy

    gpt_summary=yes
    [ "$force_gpt" = false ] && gpt_summary=no

    printf '%s\n' 'Reinstall plan'
    printf '%s\n' '=============='
    printf 'Debian:              %s (%s)\n' 13 "$suite"
    printf 'Mirror:              %s\n' "$mirror"
    printf 'Proxy:               %s\n' "$proxy_summary"
    printf 'Target disk:         %s\n' "${disk:-auto}"
    printf 'Force GPT:           %s\n' "$gpt_summary"
    printf 'Filesystem:          %s\n' "$filesystem"
    printf 'Swap:                %s\n' "$swap_summary"
    printf 'Kernel:              Debian default\n'
    printf 'Install recommends:  %s\n' "$install_recommends"
    printf 'Hostname:            %s\n' "$hostname"
    printf 'Timezone:            %s\n' "$timezone"
    printf 'NTP:                 %s\n' "$ntp"
    printf 'Account:             %s\n' "$username"
    printf 'Auth:                %s\n' "$auth"
    printf 'Sudo:                %s\n' "$sudo_mode"
    printf 'SSH port:            %s\n' "$ssh_port"
    printf 'Network interface:   %s\n' "$interface"
    [ -n "$ip" ] && printf 'IPv4:                %s via %s\n' "$ip" "$gateway"
    [ -n "$ip6" ] && printf 'IPv6:                %s via %s\n' "$ip6" "$gateway6"
    [ -z "$ip6" ] && printf '%s\n' 'IPv6:                none detected'
    printf 'IPv4 addresses:      %s\n' "$(count_network_addresses "$ip4_addrs")"
    printf 'IPv6 addresses:      %s\n' "$(count_network_addresses "$ip6_addrs")"
    printf 'DNS:                 %s\n' "$dns"
    [ -n "$dns6" ] && printf 'DNS6:                %s\n' "$dns6"
    printf 'Packages:            %s\n' "$install"
    printf '\n'
}

print_done_summary() {
    printf '\n%s\n' 'Installer prepared successfully.'
    printf 'Preseed: %s/preseed.cfg\n' "${log_file%/*}"
    printf 'Log:     %s\n' "$log_file"
    printf 'GRUB:    default entry is now "reinstall"\n'
    printf '\n%s\n' 'Reboot when ready to start the unattended Debian installation:'
    printf '  sudo reboot\n'
}

show_plan() {
    clear_screen
    print_install_summary
    printf '%s\n' 'Preparing installer'
}

show_done() {
    print_done_summary
}

print_dry_run() {
    printf '%s\n' '# --- preseed.cfg ---'
    write_preseed
    write_late_script
    printf '\n%s\n' '# --- GRUB menuentry ---'
    install_grub_entry
}

emit_late_command_preseed() {
    late_command='true'
    if [ -n "$target_script_body" ]; then
        late_command="$late_command; cp /late-command.sh /target/root/reinstall-late-command.sh; chmod +x /target/root/reinstall-late-command.sh; in-target sh /root/reinstall-late-command.sh; rm -f /target/root/reinstall-late-command.sh"
    fi

    printf '%s\n' "d-i preseed/late_command string $late_command" | ps_raw
}

write_late_script() {
    [ -n "$target_script_body" ] || return 0

    if [ "$dry_run" = true ]; then
        printf '\n%s\n' '# --- late-command.sh ---'
        printf '%s\n' '#!/bin/sh'
        printf '%s\n' 'set -e'
        printf '%s' "$target_script_body"
    else
        {
            printf '%s\n' '#!/bin/sh'
            printf '%s\n' 'set -e'
            printf '%s' "$target_script_body"
        } > late-command.sh
    fi
}

split_mirror_url() {
    mirror=${1%/}

    case $mirror in
        http://*|https://*|ftp://*)
            ;;
        *)
            die '"--mirror" must be an http, https or ftp URL'
            ;;
    esac

    mirror_protocol=${mirror%%://*}
    mirror_rest=${mirror#*://}
    mirror_host=${mirror_rest%%/*}

    if [ "$mirror_host" = "$mirror_rest" ]; then
        mirror_directory=/
    else
        mirror_directory=/${mirror_rest#*/}
    fi

    [ -n "$mirror_host" ] || die '"--mirror" URL is missing a hostname'

    case $mirror_directory in
        */debian)
            security_repository=${mirror%/debian}/debian-security
            ;;
        *)
            security_repository=$mirror/debian-security
            ;;
    esac
}

validate_config() {
    case $swap_size in
        ''|*[!0-9]*)
            die '"--swap" must be a number of MiB'
            ;;
    esac

    validate_port
    validate_username

    if [ -z "$ip" ]; then
        detect_primary_network
    fi

    if [ -z "$ip" ] && [ -z "$ip6" ]; then
        if [ "$dry_run" = true ]; then
            return 0
        fi
        die 'Cannot detect current IPv4 or IPv6 address'
    fi
    if [ -n "$ip" ] && [ -z "$gateway" ]; then
        die 'Cannot detect current IPv4 gateway'
    fi
    if [ -n "$ip" ] && [ -z "$interface" ]; then
        die 'Cannot detect current IPv4 interface'
    fi
    if [ "$auto_static_network" = true ] && [ -n "$ip6" ] && [ -z "$gateway6" ]; then
        die 'Cannot detect current IPv6 gateway'
    fi
    if [ "$auto_static_network" = true ] && [ -n "$ip6" ] && [ -z "$interface6" ]; then
        die 'Cannot detect current IPv6 interface'
    fi

    return 0
}

derive_install_plan() {
    swap_partman_size=$(((swap_size * 1048576 + 999999) / 1000000))

    if [ -z "$ip" ] && [ -n "$ip6" ]; then
        ip6_addr=$(printf '%s\n' "$ip6" | cut -d/ -f1)
        ip6_prefix=$(printf '%s\n' "$ip6" | cut -s -d/ -f2)
        ip=$ip6_addr
        netmask=$ip6_prefix
        gateway=$gateway6
        interface=$interface6
    fi

    detect_arch
    kernel_package="linux-image-$architecture"

    if [ -n "$authorized_keys_url" ] && ! fetch_file "$authorized_keys_url" /dev/null; then
        die "Failed to download SSH authorized public keys from \"$authorized_keys_url\""
    fi

    has_authorized_keys=false
    if [ -n "$authorized_keys_url" ] || [ -n "$authorized_key" ]; then
        has_authorized_keys=true
    fi

    apt_components='main non-free-firmware'
    apt_services='updates, backports'
    apt_src=false
    apt_contrib=false
    apt_non_free=false
    apt_non_free_firmware=true
    configure_chrony

    installer_directory="/boot/debian-$suite"
    log_file="$installer_directory/reinstall.log"

    :
}

emit_locale_preseed() {
    ps_raw << EOF
# Localization

d-i debian-installer/language string en
d-i debian-installer/country string US
d-i debian-installer/locale string en_US.UTF-8
d-i keyboard-configuration/xkb-keymap select us
EOF
}

emit_network_preseed() {
    ps_raw << EOF

# Network configuration

d-i netcfg/choose_interface select $interface
EOF

    [ "$auto_static_network" = true ] && {
        echo "# detected IPv4 addresses: $(count_network_addresses "$ip4_addrs")" | ps_raw
        echo "# detected IPv6 addresses: $(count_network_addresses "$ip6_addrs")" | ps_raw
    }

    [ -n "$ip" ] && {
        echo 'd-i netcfg/disable_autoconfig boolean true' | ps_raw
        echo "d-i netcfg/get_ipaddress string $ip" | ps_raw
        [ -n "$netmask" ] && echo "d-i netcfg/get_netmask string $netmask" | ps_raw
        [ -n "$gateway" ] && echo "d-i netcfg/get_gateway string $gateway" | ps_raw
        [ -z "${ip%%*:*}" ] && [ -n "${dns%%*:*}" ] && dns="$dns6"
        [ -n "$dns" ] && echo "d-i netcfg/get_nameservers string $dns" | ps_raw
        echo 'd-i netcfg/confirm_static boolean true' | ps_raw
    }

    echo "d-i netcfg/hostname string $hostname" | ps_raw
    domain=

    ps_raw << EOF
d-i netcfg/get_hostname string $hostname
d-i netcfg/get_domain string$domain
EOF

    echo 'd-i hw-detect/load_firmware boolean true' | ps_raw
}

emit_network_console_preseed() {
    [ "$network_console" = true ] || return 0

    ps_raw << 'EOF'

# Network console

d-i anna/choose_modules string network-console
d-i preseed/early_command string anna-install network-console
EOF
    if [ -n "$authorized_keys_url" ]; then
        echo "d-i network-console/authorized_keys_url string $authorized_keys_url" | ps_raw
    else
        ps_raw << EOF
d-i network-console/password password $password
d-i network-console/password-again password $password
EOF
    fi

    echo 'd-i network-console/start select Continue' | ps_raw
}

emit_mirror_preseed() {
    ps_raw << EOF

# Mirror settings

d-i mirror/country string manual
d-i mirror/protocol string $mirror_protocol
d-i mirror/$mirror_protocol/hostname string $mirror_host
d-i mirror/$mirror_protocol/directory string $mirror_directory
d-i mirror/$mirror_protocol/proxy string $proxy
d-i mirror/suite string $suite
EOF
}

emit_account_preseed() {
    password_hash=$(mkpasswd -m sha-256 "$password" 2> /dev/null) ||
    password_hash=$(openssl passwd -5 "$password" 2> /dev/null) ||
    password_hash=$(busybox mkpasswd -m sha256 "$password" 2> /dev/null) || {
        for python in python3 python python2; do
            password_hash=$("$python" -c 'import crypt, sys; print(crypt.crypt(sys.argv[1], crypt.mksalt(crypt.METHOD_SHA256)))' "$password" 2> /dev/null) && break
        done
    }

    ps_raw << 'EOF'

# Account setup

EOF
    [ "$has_authorized_keys" = true ] && configure_sshd PasswordAuthentication no

    if [ "$username" = root ]; then
        if [ "$has_authorized_keys" = false ]; then
            configure_sshd PermitRootLogin yes
        else
            target_script_add 'create root .ssh' "mkdir -m 0700 -p ~root/.ssh"
            [ -n "$authorized_keys_url" ] &&
            target_script_add 'append root authorized keys URL' "busybox wget -O- \"$authorized_keys_url\" >> ~root/.ssh/authorized_keys"
            [ -n "$authorized_key" ] && target_script_add 'append root literal authorized key' "printf '%s\n' $(sh_quote "$authorized_key") >> ~root/.ssh/authorized_keys"
        fi

    ps_raw << 'EOF'
d-i passwd/root-login boolean true
d-i passwd/make-user boolean false
EOF

        if [ -z "$password_hash" ]; then
            ps_raw << EOF
d-i passwd/root-password password $password
d-i passwd/root-password-again password $password
EOF
        else
            echo "d-i passwd/root-password-crypted password $password_hash" | ps_raw
        fi
    else
        configure_sshd PermitRootLogin no

        if [ -n "$authorized_keys_url" ] || [ -n "$authorized_key" ]; then
            target_script_add 'create user .ssh' "sudo -u $username mkdir -m 0700 -p ~$username/.ssh"
        fi

        [ -n "$authorized_keys_url" ] &&
        target_script_add 'append user authorized keys URL' "busybox wget -O - \"$authorized_keys_url\" | sudo -u $username tee -a ~$username/.ssh/authorized_keys"

        [ -n "$authorized_key" ] &&
        target_script_add 'append user literal authorized key' "printf '%s\n' $(sh_quote "$authorized_key") | sudo -u $username tee -a ~$username/.ssh/authorized_keys"

        [ "$sudo_with_password" = false ] &&
        target_script_add 'write passwordless sudoers file' "echo \"$username ALL=(ALL:ALL) NOPASSWD:ALL\" > \"/etc/sudoers.d/90-user-$username\""

        ps_raw << EOF
d-i passwd/root-login boolean false
d-i passwd/make-user boolean true
d-i passwd/user-fullname string
d-i passwd/username string $username
EOF

        if [ -z "$password_hash" ]; then
            ps_raw << EOF
d-i passwd/user-password password $password
d-i passwd/user-password-again password $password
EOF
        else
            echo "d-i passwd/user-password-crypted password $password_hash" | ps_raw
        fi
    fi

    [ -n "$ssh_port" ] && configure_sshd Port "$ssh_port"
}

emit_clock_preseed() {
    ps_raw << EOF

# Clock and time zone setup

d-i time/zone string $timezone
d-i clock-setup/utc boolean true
d-i clock-setup/ntp boolean true
d-i clock-setup/ntp-server string $ntp
EOF
}

emit_storage_preseed() {
    ps_raw << EOF

# Partitioning

EOF

    ps_raw << 'EOF'
d-i partman-auto/method string regular
EOF
    if [ -n "$disk" ]; then
        echo "d-i partman-auto/disk string $disk" | ps_raw
    else
        # shellcheck disable=SC2016
        echo 'd-i partman/early_command string debconf-set partman-auto/disk "$(list-devices disk | head -n 1)"' | ps_raw
    fi

    [ "$force_gpt" = true ] && {
        ps_raw << 'EOF'
d-i partman-partitioning/choose_label string gpt
d-i partman-partitioning/default_label string gpt
EOF
    }

    echo "d-i partman/default_filesystem string $filesystem" | ps_raw

    efi=false
    [ -d /sys/firmware/efi ] && efi=true

    ps_raw << 'EOF'
d-i partman-auto/expert_recipe string \
    naive :: \
EOF
    if [ "$efi" = true ]; then
        ps_raw << 'EOF'
        106 106 106 free \
            $iflabel{ gpt } \
            $reusemethod{ } \
            method{ efi } \
            format{ } \
        . \
EOF
    else
        ps_raw << 'EOF'
        1 1 1 free \
            $iflabel{ gpt } \
            $reusemethod{ } \
            method{ biosgrub } \
        . \
EOF
    fi

    if [ "$swap_size" -gt 0 ]; then
        ps_raw << EOF
        $swap_partman_size 200 $swap_partman_size linux-swap \\
            method{ swap } \\
            format{ } \\
        . \\
EOF
    fi

    ps_raw << 'EOF'
        1075 1076 -1 $default_filesystem \
            method{ format } \
            format{ } \
            use_filesystem{ } \
            $default_filesystem{ } \
            mountpoint{ / } \
        .
EOF
    if [ "$efi" = true ]; then
        echo 'd-i partman-efi/non_efi_system boolean true' | ps_raw
    fi

    ps_raw << 'EOF'
d-i partman-auto/choose_recipe select naive
d-i partman-basicfilesystems/no_swap boolean false
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
d-i partman-lvm/device_remove_lvm boolean true
EOF
}

emit_base_preseed() {
    ps_raw << EOF

# Base system installation

d-i base-installer/kernel/image string $kernel_package
EOF

    echo "d-i base-installer/install-recommends boolean $install_recommends" | ps_raw
}

emit_apt_preseed() {
    ps_raw << EOF

# Apt setup

d-i apt-setup/contrib boolean $apt_contrib
d-i apt-setup/non-free boolean $apt_non_free
d-i apt-setup/enable-source-repositories boolean $apt_src
d-i apt-setup/services-select multiselect $apt_services
d-i apt-setup/non-free-firmware boolean $apt_non_free_firmware
d-i apt-setup/local0/repository string $security_repository trixie-security $apt_components
d-i apt-setup/local0/source boolean $apt_src
EOF
}

emit_package_preseed() {
    ps_raw << 'EOF'

# Package selection

tasksel tasksel/first multiselect ssh-server
EOF

    [ -n "$install" ] && echo "d-i pkgsel/include string $install" | ps_raw

    ps_raw << 'EOF'
popularity-contest popularity-contest/participate boolean false
EOF
}

emit_bootloader_preseed() {
    ps_raw << 'EOF'

# Boot loader installation

EOF

    if [ -n "$disk" ]; then
        echo "d-i grub-installer/bootdev string $disk" | ps_raw
    else
        echo 'd-i grub-installer/bootdev string default' | ps_raw
    fi

    echo 'd-i grub-installer/force-efi-extra-removable boolean true' | ps_raw
    if [ -n "$kernel_params" ]; then
        echo "d-i debian-installer/add-kernel-opts string$kernel_params" | ps_raw
    fi
}

emit_finish_preseed() {
    local ip4_addr=
    local ip6_addr=
    local network_late_commands=

    ps_raw << 'EOF'

# Finishing up the installation

EOF

    echo 'd-i finish-install/reboot_in_progress note' | ps_raw

    network_late_commands=false
    if [ "$auto_static_network" = true ]; then
        for ip4_addr in $ip4_addrs; do
            [ "$ip4_addr" = "$ip" ] || network_late_commands=true
        done
        [ -n "$ip6_addrs" ] && network_late_commands=true
        [ -n "$gateway6" ] && network_late_commands=true
    fi

    [ "$auto_static_network" = true ] &&
    [ "$network_late_commands" = true ] &&
    target_script_add 'detect installed static interface' "static_interface=\$(grep -E \"^iface .* inet static\" /etc/network/interfaces | head -n 1 | cut -d \" \" -f 2); if [ -z \"\$static_interface\" ]; then static_interface=$interface; fi"

    [ "$auto_static_network" = true ] &&
    [ "$network_late_commands" = true ] && {
        for ip4_addr in $ip4_addrs; do
            [ "$ip4_addr" = "$ip" ] && continue
            target_script_add "append extra IPv4 address $ip4_addr" "grep -Fq \"ip addr add $ip4_addr\" /etc/network/interfaces || echo \"        up ip addr add $ip4_addr dev \$static_interface\" >> /etc/network/interfaces"
        done
    }

    [ "$auto_static_network" = true ] &&
    [ "$network_late_commands" = true ] && {
        for ip6_addr in $ip6_addrs; do
            target_script_add "append IPv6 address $ip6_addr" "grep -Fq \"ip -6 addr add $ip6_addr\" /etc/network/interfaces || echo \"        up ip -6 addr add $ip6_addr dev \$static_interface\" >> /etc/network/interfaces"
        done
        [ -n "$gateway6" ] && target_script_add 'append IPv6 gateway route' "grep -Fq \"ip -6 route add $gateway6\" /etc/network/interfaces || echo \"        up ip -6 route add $gateway6 dev \$static_interface\" >> /etc/network/interfaces"
        [ -n "$gateway6" ] && target_script_add 'append IPv6 default route' "grep -Fq \"ip -6 route add default via $gateway6\" /etc/network/interfaces || echo \"        up ip -6 route add default via $gateway6 dev \$static_interface\" >> /etc/network/interfaces"
    }

    emit_late_command_preseed
}

write_preseed() {
    emit_locale_preseed
    emit_network_preseed
    emit_network_console_preseed
    emit_mirror_preseed
    emit_account_preseed
    emit_clock_preseed
    emit_storage_preseed
    emit_base_preseed
    emit_apt_preseed
    emit_package_preseed
    emit_bootloader_preseed
    emit_finish_preseed
}

prepare_workdir() {
    [ "$(id -u)" -ne 0 ] && die 'root privilege is required'
    rm -rf "$installer_directory"
    mkdir -p "$installer_directory"
    cd "$installer_directory"
    : > "$log_file"
}

prepare_netboot_files() {
    base_url="$mirror/dists/$suite/main/installer-$architecture/current/images/netboot/debian-installer/$architecture"

    run_logged 'Download installer kernel' fetch_file "$base_url/linux" linux
    run_logged 'Download installer initrd' fetch_file "$base_url/initrd.gz" initrd.gz

    run_logged 'Unpack installer initrd' gzip -d initrd.gz
}

inject_preseed() {
    local initrd_files=

    printf '  - Inject preseed into initrd... '
    initrd_files=preseed.cfg
    [ -s late-command.sh ] && initrd_files="$initrd_files
late-command.sh"

    # cpio reads a list of file names from the standard input
    if printf '%s\n' "$initrd_files" | cpio -o -H newc -A -F initrd >> "$log_file" 2>&1; then
        printf 'done\n'
    else
        printf 'failed\n' 1>&2
        printf 'Log: %s\n' "$log_file" 1>&2
        exit 1
    fi

    run_logged 'Compress installer initrd' gzip -1 initrd
}

install_grub_entry() {
    if [ "$dry_run" = false ]; then
        mkdir -p /etc/default/grub.d
        cat > /etc/default/grub.d/zz-reinstall.cfg << EOF
GRUB_DEFAULT=reinstall
GRUB_TIMEOUT=5
GRUB_TIMEOUT_STYLE=menu
EOF

        if has_cmd update-grub; then
            grub_cfg=/boot/grub/grub.cfg
            run_logged 'Update GRUB configuration' update-grub
        elif has_cmd grub2-mkconfig; then
            tmp=$(mktemp)
            grep -vF zz_reinstall /etc/default/grub > "$tmp"
            cat "$tmp" > /etc/default/grub
            rm "$tmp"
            # shellcheck disable=SC2016
            echo 'zz_reinstall=/etc/default/grub.d/zz-reinstall.cfg; if [ -f "$zz_reinstall" ]; then . "$zz_reinstall"; fi' >> /etc/default/grub
            grub_cfg=/boot/grub2/grub.cfg
            if [ -d /sys/firmware/efi ]; then
                grub_cfg=/boot/efi/EFI/*/grub.cfg
            fi
            run_logged 'Update GRUB configuration' grub2-mkconfig -o "$grub_cfg"
        elif has_cmd grub-mkconfig; then
            tmp=$(mktemp)
            grep -vF zz_reinstall /etc/default/grub > "$tmp"
            cat "$tmp" > /etc/default/grub
            rm "$tmp"
            # shellcheck disable=SC2016
            echo 'zz_reinstall=/etc/default/grub.d/zz-reinstall.cfg; if [ -f "$zz_reinstall" ]; then . "$zz_reinstall"; fi' >> /etc/default/grub
            grub_cfg=/boot/grub/grub.cfg
            run_logged 'Update GRUB configuration' grub-mkconfig -o "$grub_cfg"
        else
            die 'Could not find "update-grub" or "grub2-mkconfig" or "grub-mkconfig" command'
        fi
    fi

    mkrelpath=$installer_directory
    if [ "$dry_run" = true ]; then
        mkrelpath=/boot
    fi
    if installer_directory=$(grub-mkrelpath "$mkrelpath" 2> /dev/null); then
        :
    elif installer_directory=$(grub2-mkrelpath "$mkrelpath" 2> /dev/null); then
        :
    elif [ "$dry_run" = true ]; then
        installer_directory=/boot
    else
        die 'Could not find "grub-mkrelpath" or "grub2-mkrelpath" command'
    fi
    if [ "$dry_run" = true ]; then
        installer_directory="$installer_directory/debian-$suite"
    fi

    kernel_params="$kernel_params auto=true priority=critical lowmem/low=1"

    initrd="$installer_directory/initrd.gz"

    save_grub_cfg << EOF
menuentry 'Debian Installer' --id reinstall {
    insmod part_msdos
    insmod part_gpt
    insmod ext2
    insmod xfs
    insmod btrfs
    linux $installer_directory/linux$kernel_params
    initrd $initrd
}
EOF
}

set_debian_version() {
    case $1 in
        13|trixie)
            suite=trixie
            ;;
        *)
            die "Only Debian 13 trixie is supported"
    esac
}

init_defaults() {
    # CLI option defaults
    dns='8.8.8.8 1.1.1.1'
    dns6='2001:4860:4860::8888 2606:4700:4700::1111'
    hostname=linuxserver
    network_console=false
    set_debian_version 13
    split_mirror_url https://deb.debian.org/debian
    proxy=${https_proxy-}
    username=root
    password=
    authorized_keys_url=
    authorized_key=
    sudo_with_password=false
    timezone=UTC
    ntp=time.google.com
    disk=
    force_gpt=true
    filesystem=ext4
    swap_size=0
    install_recommends=true
    install=
    ssh_port=22
    dry_run=false

    # Internal state
    interface=auto
    ip=
    netmask=
    gateway=
    ip6=
    gateway6=
    interface6=
    ip4_addrs=
    ip6_addrs=
    auto_static_network=false
    kernel_package=
    kernel_params=
    architecture=
}

parse_cli() {
    while [ $# -gt 0 ]; do
        case $1 in
            --google)
                dns='8.8.8.8 1.1.1.1'
                dns6='2001:4860:4860::8888 2606:4700:4700::1111'
                ntp=time.google.com
                ;;
            --cloudflare)
                dns='1.1.1.1 1.0.0.1'
                dns6='2606:4700:4700::1111 2606:4700:4700::1001'
                ntp=time.cloudflare.com
                ;;
            --china)
                dns='223.5.5.5 119.29.29.29'
                dns6='2400:3200::1 2402:4e00::'
                split_mirror_url https://mirrors.tuna.tsinghua.edu.cn/debian
                ntp=ntp.cloud.aliyuncs.com
                timezone=Asia/Shanghai
                ;;
            --dns)
                dns=$2
                shift
                ;;
            --dns6)
                dns6=$2
                shift
                ;;
            --hostname)
                hostname=$2
                shift
                ;;
            --network-console)
                network_console=true
                ;;
            --version)
                set_debian_version "$2"
                shift
                ;;
            --mirror)
                split_mirror_url "$2"
                shift
                ;;
            --proxy)
                proxy=$2
                shift
                ;;
            --username)
                username=$2
                shift
                ;;
            --password)
                password=$2
                shift
                ;;
            --authorized-keys-url)
                authorized_keys_url=$2
                shift
                ;;
            --authorized-key)
                authorized_key=$2
                shift
                ;;
            --sudo-with-password)
                sudo_with_password=true
                ;;
            --timezone)
                timezone=$2
                shift
                ;;
            --ntp)
                ntp=$2
                shift
                ;;
            --disk)
                disk=$2
                shift
                ;;
            --no-force-gpt)
                force_gpt=false
                ;;
            --filesystem)
                filesystem=$2
                shift
                ;;
            --swap)
                swap_size=$2
                shift
                ;;
            --install-recommends)
                install_recommends=true
                ;;
            --no-install-recommends)
                install_recommends=false
                ;;
            --install)
                append_plan_package_list "$2"
                shift
                ;;
            --ethx)
                kernel_params="$kernel_params net.ifnames=0 biosdevname=0"
                ;;
            --ssh-port)
                ssh_port=$2
                shift
                ;;
            --dry-run)
                dry_run=true
                ;;
            *)
                die "Unknown option: \"$1\""
        esac
        shift
    done
}

main() {
    init_defaults
    parse_cli "$@"
    detect_disk

    validate_config
    derive_install_plan

    if [ "$dry_run" = true ]; then
        prompt_password_if_needed
        print_dry_run
        return
    fi

    prepare_workdir
    prompt_password_if_needed
    write_preseed
    write_late_script
    show_plan
    prepare_netboot_files
    inject_preseed
    install_grub_entry
    show_done
}

main "$@"
