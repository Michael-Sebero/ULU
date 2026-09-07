#!/bin/bash

su -c '
if command -v pacman &>/dev/null; then

##############################
# ARTIX / ARCH LINUX SECTION #
##############################

### DISTRO DETECTION ###

detect_distro() {
    local os_id
    os_id=$(. /etc/os-release 2>/dev/null; echo "$ID")
    case "$os_id" in
        artix)
            echo "artix"
            ;;
        *)
            echo "arch"
            ;;
    esac
}

DISTRO=$(detect_distro)

### RESOLVE INIT-SPECIFIC PACKAGE NAME ###

init_pkg() {
    local base_pkg="$1"
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        echo "$base_pkg"
    else
        echo "${base_pkg}-${INIT_SYSTEM}"
    fi
}

### INIT SYSTEM DETECTION ###

detect_init_system() {
    if pacman -Qi runit &>/dev/null; then
        echo "runit"
        return
    fi
    if pacman -Qi dinit &>/dev/null; then
        echo "dinit"
        return
    fi
    case "$(ps -p 1 -o comm=)" in
        s6-svscan)
            echo "s6"
            ;;
        dinit)
            echo "dinit"
            ;;
        init|openrc-init)
            echo "openrc"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

if [ "$DISTRO" = "artix" ]; then
    INIT_SYSTEM=$(detect_init_system)
else
    INIT_SYSTEM="systemd"
fi

### CPU MICROARCHITECTURE DETECTION ###

detect_cpu_level() {
    local lvl

    lvl=$(/lib/ld-linux-x86-64.so.2 --help 2>&1 \
            | grep -v '\''not supported'\'' \
            | grep -E '\''\(supported'\'' \
            | head -n 1 | awk '\''{print $1}'\'')
    case "$lvl" in
        x86-64-v4) echo "v4" ;;
        x86-64-v3) echo "v3" ;;
        *)         echo "" ;;
    esac
}

write_pacman_conf() {
    local distro="$1" cpu_level="$2" alhp_ok="$3"
    local arch_line base_mirrorlist native_repos tiered_repos repo

    case "$cpu_level" in
        v3) arch_line="x86_64 x86_64_v3" ;;
        v4) arch_line="x86_64 x86_64_v4" ;;
        *)  arch_line="auto" ;;
    esac

    if [ "$distro" = "artix" ]; then
        native_repos="system world galaxy lib32"
        tiered_repos="extra multilib"
        base_mirrorlist="/etc/pacman.d/mirrorlist-arch"
    else
        native_repos=""
        tiered_repos="core extra multilib"
        base_mirrorlist="/etc/pacman.d/mirrorlist"
    fi

    {
        printf '\''[options]\nHoldPkg     = pacman glibc\nArchitecture = %s\nColor\nParallelDownloads = 10\nSigLevel    = Required DatabaseOptional\nLocalFileSigLevel = Optional\n\n'\'' "$arch_line"

        for repo in $native_repos; do
            printf '\''[%s]\nInclude = /etc/pacman.d/mirrorlist\n\n'\'' "$repo"
        done

        for repo in $tiered_repos; do
            if [ "$alhp_ok" = "true" ]; then
                [ "$cpu_level" = "v4" ] && printf '\''[%s-x86-64-v4]\nInclude = /etc/pacman.d/alhp-mirrorlist\n\n'\'' "$repo"
                { [ "$cpu_level" = "v3" ] || [ "$cpu_level" = "v4" ]; } && printf '\''[%s-x86-64-v3]\nInclude = /etc/pacman.d/alhp-mirrorlist\n\n'\'' "$repo"
            fi
            printf '\''[%s]\nInclude = %s\n\n'\'' "$repo" "$base_mirrorlist"
        done

        [ "$distro" = "artix" ] && printf '\''[auris]\nSigLevel = Required\nServer = https://auris.artixlinux.org/api/packages/auris/arch/$repo/$arch\n\n'\''

        printf '\''[chaotic-aur]\nInclude = /etc/pacman.d/chaotic-mirrorlist\n'\''
    } > /etc/pacman.conf
}

### INSTALL PACKAGES ONE BY ONE WITH RETRIES ###

careful_install() {
  local failed_packages=()
  for pkg in "$@"; do
    local success=false
    for attempt in $(seq 1 5); do
      echo "Installing $pkg (attempt $attempt/5)..." >&2
      if paru -S --noconfirm --needed --ignore=nvidia-390xx-utils,lib32-nvidia-390xx-utils,modemmanager "$pkg"; then
        success=true
        break
      else
        if [ "$attempt" -lt 5 ]; then
          echo "Attempt $attempt failed for $pkg, retrying in 5 seconds..." >&2
          sleep 5
        else
          echo "All 5 attempts failed for $pkg, skipping..." >&2
          failed_packages+=("$pkg")
        fi
      fi
    done
  done

  if [ "${#failed_packages[@]}" -gt 0 ]; then
    echo -e "\e[1mThe following packages failed to install and were skipped:\e[0m" >&2
    for pkg in "${failed_packages[@]}"; do
      echo "  - $pkg" >&2
    done
  fi
}

### SERVICE MANAGEMENT FUNCTIONS ###

s6_resolve_name() {
    local name="$1" candidate known
    known=$(s6-rc-db list all 2>/dev/null)
    for candidate in "$name" "${name,,}" "${name}-srv" "${name,,}-srv"; do
        if grep -qx "$candidate" <<< "$known"; then
            echo "$candidate"
            return
        fi
    done
    for candidate in "$name" "${name,,}" "${name}-srv" "${name,,}-srv"; do
        if [ -d "/etc/s6/sv/$candidate" ] || [ -d "/etc/s6/adminsv/$candidate" ]; then
            echo "$candidate"
            return
        fi
    done
    echo "$name"
}

S6_REPO_SYNCED=false
s6_sync_repo_once() {
    if [ "$S6_REPO_SYNCED" != "true" ] && command -v s6 >/dev/null 2>&1; then
        s6 repository sync >/dev/null 2>&1 || true
        S6_REPO_SYNCED=true
    fi
}

add_service() {
    local service_name="$1"
    case "$INIT_SYSTEM" in
        s6)
            local s6_name
            s6_name=$(s6_resolve_name "$service_name")
            if command -v s6 >/dev/null 2>&1; then
                if ! s6 set enable -p "$s6_name" >/dev/null 2>&1; then
                    s6_sync_repo_once
                    if ! s6 set enable -p "$s6_name" >/dev/null 2>&1; then
                        echo "Warning: s6 set enable $s6_name failed even after a repository sync; falling back to legacy contents.d (may not take effect on newer s6-frontend setups)." >&2
                        if [ -d "/etc/s6/sv/$s6_name" ] || [ -d "/etc/s6/adminsv/$s6_name" ]; then
                            mkdir -p /etc/s6/adminsv/default/contents.d
                            touch "/etc/s6/adminsv/default/contents.d/$s6_name"
                        else
                            echo "Warning: could not enable or locate an s6 service for $service_name, resolved as $s6_name." >&2
                        fi
                    fi
                fi
            elif [ -d "/etc/s6/sv/$s6_name" ] || [ -d "/etc/s6/adminsv/$s6_name" ]; then
                mkdir -p /etc/s6/adminsv/default/contents.d
                touch "/etc/s6/adminsv/default/contents.d/$s6_name"
            fi
            ;;
        openrc)
            rc-update add "$service_name" default
            ;;
        runit)
            ln -sf "/etc/runit/sv/$service_name" /etc/runit/runsvdir/default/
            ;;
        dinit)
            ln -sf "/etc/dinit.d/$service_name" /etc/dinit.d/boot.d/
            ;;
        systemd)
            systemctl enable "$service_name" &>/dev/null || true
            ;;
    esac
}

remove_service() {
    local service_name="$1"
    case "$INIT_SYSTEM" in
        s6)
            local s6_name
            s6_name=$(s6_resolve_name "$service_name")
            if command -v s6 >/dev/null 2>&1; then
                if ! s6 set disable "$s6_name" >/dev/null 2>&1; then
                    s6_sync_repo_once
                    if ! s6 set disable "$s6_name" >/dev/null 2>&1; then
                        rm -f "/etc/s6/adminsv/default/contents.d/$s6_name" 2>/dev/null || true
                    fi
                fi
            else
                rm -f "/etc/s6/adminsv/default/contents.d/$s6_name" 2>/dev/null || true
            fi
            ;;
        openrc)
            rc-update del "$service_name" default || true
            ;;
        runit)
            unlink "/etc/runit/runsvdir/default/$service_name" 2>/dev/null || true
            ;;
        dinit)
            unlink "/etc/dinit.d/boot.d/$service_name" 2>/dev/null || true
            ;;
        systemd)
            systemctl disable "$service_name" &>/dev/null || true
            ;;
    esac
}

reload_s6_db() {
    if [ "$INIT_SYSTEM" = "s6" ]; then
        if command -v s6 >/dev/null 2>&1; then
            if s6 set commit -f; then
                if ! s6 live install --init; then
                    echo "Warning: s6 live install --init failed; service changes were compiled but not applied to the boot database." >&2
                fi
            else
                echo "Warning: s6 set commit failed; run s6 set check after boot to see what is inconsistent." >&2
            fi
        elif command -v s6-db-reload >/dev/null 2>&1; then
            s6-db-reload
        fi
    fi
}

### ULU CHOICE SELECTION ###

echo -e "\e[1mSelect a ULU Variant\e[0m"
echo "1. AMD-DESKTOP"
echo "2. AMD-LAPTOP"
echo "3. INTEL-DESKTOP"
echo "4. INTEL-LAPTOP"
echo "5. NVIDIA-OPENSOURCE-DESKTOP"
echo "6. NVIDIA-PROPRIETARY-DESKTOP"

read -p "Enter your choice (1-6): " choice

# IMPORT KEYS
echo -e "\e[1mImporting repository keys...\e[0m"

# AUR
curl -s https://raw.githubusercontent.com/chaotic-aur/.github/refs/heads/main/profile/README.md \
| grep -Eo "pacman-key --recv-key [0-9A-F]+" \
| sed "s/--recv-key \([0-9A-F]*\)/--recv-key \1; pacman-key --lsign-key \1/" \
| bash

# AURIS
if [ "$DISTRO" = "artix" ]; then
    curl https://auris.artixlinux.org/api/packages/auris/arch/repository.key -o repository.key
    gpg --show-keys repository.key
    pacman-key --add repository.key
    pacman-key --lsign-key 74E5750C4A3C00F037070EF2357B525A97500B9F
fi

### FIRST COMMANDS AND ULU IMPORT P1 ###

# INITIALIZE KEYRING (must run before any pacman/paru call that checks signatures)
pacman-key --init

pacman -Sy --noconfirm --needed p7zip unzip git base-devel
mkdir /home/ulu-files/
git clone https://github.com/Michael-Sebero/ULU /home/ulu-files/
cd /home/ulu-files/files/ulu-packages/
if [ "$DISTRO" = "artix" ]; then
    pacman -Sy --noconfirm artix-archlinux-support pacman-contrib artix-keyring archlinux-keyring artix-mirrorlist archlinux-mirrorlist
    pacman-key --populate archlinux artix
else
    pacman -Sy --noconfirm pacman-contrib archlinux-keyring
    pacman-key --populate archlinux
fi

pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'
pacman-key --populate chaotic

write_pacman_conf "$DISTRO" "" false
pacman -Sy --noconfirm --needed paru

### BUILD ALHP KEYRING / MIRRORLIST ###

build_user="ulu-builder"
alhp_ok=false
id "$build_user" >/dev/null 2>&1 || useradd -m -G wheel "$build_user"
echo "$build_user ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/99-ulu-builder
chmod 440 /etc/sudoers.d/99-ulu-builder

if runuser -l "$build_user" -c '\''paru -S --noconfirm --needed alhp-keyring alhp-mirrorlist'\''; then
  alhp_ok=true
else
  echo "Building alhp-keyring/alhp-mirrorlist failed; continuing without ALHP repos." >&2
fi
rm -f /etc/sudoers.d/99-ulu-builder
userdel -r "$build_user" >/dev/null 2>&1

### CPU ARCHITECTURE DETECTION & REPO CONFIGURATION ###

CPU_LEVEL=$(detect_cpu_level)
echo "Configuring pacman repos (distro: $DISTRO, CPU level: ${CPU_LEVEL:-baseline}, ALHP repos available: $alhp_ok)..."

repo_label="chaotic-aur"
[ "$DISTRO" = "artix" ] && repo_label="chaotic-aur/auris"

if [ -z "$CPU_LEVEL" ]; then
    echo "CPU is below x86-64-v3 — writing a baseline config with $repo_label but no ALHP repos." >&2
elif [ "$alhp_ok" != "true" ]; then
    echo "CPU supports x86-64-$CPU_LEVEL but ALHP repos failed to build — writing Architecture=x86_64 x86_64_$CPU_LEVEL with $repo_label but no ALHP repos." >&2
fi

write_pacman_conf "$DISTRO" "$CPU_LEVEL" "$alhp_ok"

# POPULATE & REFRESH
if [ "$alhp_ok" = true ]; then
    pacman-key --populate alhp
fi
pacman -Syy

# FIND QUICKEST MIRRORLIST
rank_mirrors() {
    local out ok=false
    out=$(mktemp) || return 1

    if [ "$DISTRO" = "artix" ]; then
        rankmirrors -n 5 -m 3 /etc/pacman.d/mirrorlist > "$out" \
            && grep -q "^Server" "$out" && ok=true
    elif pacman -S --noconfirm --needed rate-mirrors \
            && timeout 120 rate-mirrors --allow-root --save="$out" --protocol https arch --max-delay=43200 \
            && grep -q "^Server" "$out"; then
        ok=true
    elif pacman -S --noconfirm --needed reflector \
            && timeout 90 reflector --protocol https --age 12 --latest 100 --number 10 --sort rate \
                   --threads 20 --connection-timeout 3 --download-timeout 3 --save "$out" \
            && grep -q "^Server" "$out"; then
        ok=true
    fi

    if [ "$ok" = true ] \
        && install -m 644 "$out" /etc/pacman.d/mirrorlist.new \
        && mv -f /etc/pacman.d/mirrorlist.new /etc/pacman.d/mirrorlist; then
        rm -f "$out"
        return 0
    fi
    rm -f "$out" /etc/pacman.d/mirrorlist.new
    return 1
}

(
    set +m
    echo -ne "\033[1mFinding quickest mirrorlist, please wait... 0s\033[0m"
    seconds=0
    rank_mirrors &>/tmp/ulu-mirror-rank.log &
    RANK_PID=$!
    while kill -0 $RANK_PID 2>/dev/null; do
        sleep 1
        seconds=$((seconds + 1))
        echo -ne "\r\033[1mFinding quickest mirrorlist, please wait... ${seconds}s\033[0m"
    done
    if wait $RANK_PID; then
        echo -e "\r\033[K\033[1mQuickest mirrorlist written (${seconds}s)\033[0m"
    else
        echo -e "\r\033[K\033[1mMirror ranking failed, keeping the existing mirrorlist (log: /tmp/ulu-mirror-rank.log)\033[0m"
    fi
)

### FIRST COMMANDS AND ULU IMPORT P2 ###

pacman -S paru --noconfirm --needed
for attempt in $(seq 1 5); do
  echo "Running full system update (attempt $attempt/5)..." >&2
  if pacman -Syyu --noconfirm --needed --overwrite='*' --ignore=linux,linux-headers,nvidia-390xx-utils,lib32-nvidia-390xx-utils,modemmanager; then
    echo "System update succeeded." >&2
    break
  else
    if [ "$attempt" -lt 5 ]; then
      echo "Attempt $attempt failed, retrying in 5 seconds..." >&2
      sleep 5
    else
      echo "All 5 attempts failed for full system update. Continuing anyway..." >&2
    fi
  fi
done

mv /home/ulu-files/files/ulu-manual/Manual /home/$USER/Desktop/

# REMOVE PACKAGES
for pkg in linux linux-headers pulseaudio pulseaudio-alsa pulseaudio-bluetooth pulseaudio-zeroconf nvidia-390xx-utils lib32-nvidia-390xx-utils modemmanager lib32-nvidia-580xx-utils; do
    if pacman -Qi "$pkg" &>/dev/null; then
        paru -Rdd --noconfirm "$pkg"
    fi
done

# INSTALL BASE PACKAGES
if [ "$DISTRO" = "artix" ]; then
    careful_install lib32-artix-archlinux-support
fi
careful_install \
  unrar flatpak \
  gamemode lib32-gamemode dnscrypt-proxy apparmor \
  clamav gufw macchanger wine-git wine-mono winetricks-git steam lynis rkhunter opendoas \
  downgrade rust usbguard chkrootkit expect earlyoom \
  inotify-tools preload dialog tree parallel sof-firmware booster vulkan-tools mimalloc mold \
  protontricks-git poetry pyenv python-pip ccache yt-dlp-git \
  lib32-libdisplay-info realtime-privileges gallery-dl tesseract-data-eng \
  scx-scheds debtap fwupd chrony dnsmasq mesa lib32-mesa tk nix

### REMOVE COMPETING NETWORK PACKAGES ###

if pacman -Qi networkmanager &>/dev/null; then
    echo "NetworkManager already installed, skipping network package replacement." >&2
else
    careful_install networkmanager

    case "$INIT_SYSTEM" in
        s6)
            careful_install networkmanager-s6
            ;;
        openrc)
            careful_install networkmanager-openrc
            ;;
        runit)
            careful_install networkmanager-runit
            ;;
        dinit)
            careful_install networkmanager-dinit
            ;;
    esac

    OTHER_NETWORK_PKGS=()
    for pkg in connman connman-s6 connman-openrc connman-runit connman-dinit connman-gtk wicd netctl dhcpcd; do
        pacman -Qi "$pkg" &>/dev/null && OTHER_NETWORK_PKGS+=("$pkg")
    done
    if [ "${#OTHER_NETWORK_PKGS[@]}" -gt 0 ]; then
        echo "Removing competing network packages: ${OTHER_NETWORK_PKGS[*]}" >&2
        for pkg in "${OTHER_NETWORK_PKGS[@]}"; do
            case "$pkg" in
                connman*)
                    if [ "$INIT_SYSTEM" = "systemd" ]; then
                        systemctl disable --now connman &>/dev/null || true
                    else
                        s6-rc -d change connmand || true
                        find /etc/s6 \( -iname "*connman*" -o -iname "*connmand*" \) -print -exec rm -rf {} + || true
                        find /etc/runit \( -iname "*connman*" -o -iname "*connmand*" \) -print -exec rm -rf {} + || true
                        find /etc/dinit.d \( -iname "*connman*" -o -iname "*connmand*" \) -print -exec rm -rf {} + || true
                    fi
                    ;;
                wicd|netctl|dhcpcd)
                    remove_service "$pkg"
                    ;;
            esac
        done
        pacman -Rdd --noconfirm "${OTHER_NETWORK_PKGS[@]}" || true
    else
        echo "No competing network packages detected." >&2
    fi
fi

# INSTALL INIT PACKAGES
case "$INIT_SYSTEM" in
    s6)
        careful_install \
          dnscrypt-proxy-s6 dnsmasq-s6 apparmor-s6 clamav-s6 \
          ufw-s6 usbguard-s6 earlyoom-s6
        ;;
    openrc)
        careful_install \
          dnscrypt-proxy-openrc dnsmasq-openrc apparmor-openrc clamav-openrc \
          ufw-openrc usbguard-openrc earlyoom-openrc
        ;;
    runit)
        careful_install \
          dnscrypt-proxy-runit dnsmasq-runit apparmor-runit clamav-runit \
          ufw-runit usbguard-runit earlyoom-runit
        ;;
    dinit)
        careful_install \
          dnscrypt-proxy-dinit dnsmasq-dinit apparmor-dinit clamav-dinit \
          ufw-dinit usbguard-dinit earlyoom-dinit
        ;;
esac

# AMD-DESKTOP CHOICE
if [ "$choice" = "1" ]; then
  if pacman -Qq | grep -q ''^thunar$''; then
    paru -Rdd --noconfirm xfce4-power-manager xfce4-battery-plugin
  fi
  careful_install \
    linux-xanmod-edge-x64v3 linux-xanmod-edge-x64v3-headers \
    vulkan-radeon lib32-vulkan-radeon protonup-git libva-utils \
    fail2ban $(init_pkg fail2ban) cpupower $(init_pkg cpupower)
fi

# AMD-LAPTOP CHOICE
if [ "$choice" = "2" ]; then
  careful_install \
    linux-x64v3 linux-x64v3-headers \
    vulkan-radeon lib32-vulkan-radeon libva-utils throttled \
    tlp $(init_pkg tlp) blueman bluez $(init_pkg bluez) brightnessctl
fi

# INTEL-DESKTOP CHOICE
if [ "$choice" = "3" ]; then
  if pacman -Qq | grep -q ''^thunar$''; then
    paru -Rdd --noconfirm xfce4-power-manager xfce4-battery-plugin
  fi
  careful_install \
    linux-xanmod-edge-x64v3 linux-xanmod-edge-x64v3-headers \
    vulkan-intel lib32-vulkan-intel protonup-git libva-utils \
    fail2ban $(init_pkg fail2ban) cpupower $(init_pkg cpupower)
fi

# INTEL-LAPTOP CHOICE
if [ "$choice" = "4" ]; then
  careful_install \
    linux-x64v3 linux-x64v3-headers \
    vulkan-intel lib32-vulkan-intel libva-utils throttled \
    tlp $(init_pkg tlp) blueman bluez $(init_pkg bluez) brightnessctl
fi

# NVIDIA-OPENSOURCE-DESKTOP CHOICE
if [ "$choice" = "5" ]; then
  if pacman -Qq | grep -q ''^thunar$''; then
    paru -Rdd --noconfirm xfce4-power-manager xfce4-battery-plugin
  fi
  careful_install \
    linux-xanmod-edge-x64v3 linux-xanmod-edge-x64v3-headers protonup-git \
    nvidia-utils $(init_pkg nvidia-utils) nvidia-settings \
    fail2ban $(init_pkg fail2ban) cpupower $(init_pkg cpupower) nvidia-open-dkms
  # lib32 NVIDIA / Vulkan fallback
  careful_install lib32-nvidia-utils || careful_install lib32-vulkan-driver
fi

# NVIDIA-PROPRIETARY-DESKTOP CHOICE
if [ "$choice" = "6" ]; then
  if pacman -Qq | grep -q ''^thunar$''; then
    paru -Rdd --noconfirm xfce4-power-manager xfce4-battery-plugin
  fi
  careful_install \
    linux-xanmod-edge-x64v3 linux-xanmod-edge-x64v3-headers protonup-git \
    nvidia-utils $(init_pkg nvidia-utils) nvidia-settings \
    fail2ban $(init_pkg fail2ban) cpupower $(init_pkg cpupower) nvidia-dkms
  # lib32 NVIDIA / Vulkan fallback
  careful_install lib32-nvidia-utils || careful_install lib32-vulkan-driver
fi

# IMPORT FLATPAK BETA REPO
flatpak remote-add flathub-beta https://flathub.org/beta-repo/flathub-beta.flatpakrepo

# INSTALL PROTON-GE
if pacman -Q protonup-git &>/dev/null; then
    su - "$USER" -c "protonup -d /home/$USER/.local/share/Steam/compatibilitytools.d/ && protonup -y"
fi

### ULU INSTALL ###

# AMD/INTEL SELECTION
if [ "$choice" = "1" ] || [ "$choice" = "3" ]; then
  unzip -o ulu-root-main.zip -d /
  unzip -o ulu-root-programs.zip -d /
  add_service fail2ban
  add_service cpupower
fi

# LAPTOP SELECTION
if [ "$choice" = "2" ] || [ "$choice" = "4" ]; then
  unzip -o ulu-root-main.zip -d /
  unzip -o ulu-root-programs.zip -d /
  unzip -o ulu-root-laptop.zip -d /
  add_service tlp
fi

# NVIDIA SELECTION
if [ "$choice" = "5" ] || [ "$choice" = "6" ]; then
  unzip -o ulu-root-main.zip -d /
  unzip -o ulu-root-programs.zip -d /
  unzip -o ulu-nvidia-patch.zip -d /
  add_service fail2ban
  add_service cpupower
fi

### LAST COMMANDS ###

# ADD SERVICES
add_service apparmor
add_service dnscrypt-proxy
add_service dnsmasq
add_service ufw
add_service earlyoom
add_service usbguard
add_service NetworkManager

# Sync repo after all package installs/removals, then commit and apply set changes
case "$INIT_SYSTEM" in
    s6)
        reload_s6_db
        ;;
    openrc)
        rc-update -u || true
        ;;
    systemd)
        systemctl daemon-reload || true
        ;;
esac

grub-mkconfig -o /boot/grub/grub.cfg

# CREATE GAMEMODE GROUP
if [ "$choice" = "1" ] || [ "$choice" = "3" ] || [ "$choice" = "5" ] || [ "$choice" = "6" ]; then
  groupadd -f gamemode
  TARGET_USER=$USER
  if [ "$TARGET_USER" = "root" ]; then
    TARGET_USER=$(find /home -mindepth 1 -maxdepth 1 -type d -printf "%f\n" | head -1)
  fi
  usermod -aG gamemode "$TARGET_USER"
  echo "Added user $TARGET_USER to gamemode group"
  if id "$TARGET_USER" | grep -o "gamemode" &>/dev/null; then
    echo "Successfully added to gamemode group"
  else
    echo "Failed to add to gamemode group"
  fi
fi

# ADD USER TO REALTIME
usermod -aG realtime "$(logname)"

# INSTALL UNIVERSAL RC.LOCAL

# s6
if [ -d /etc/s6 ]; then
  mv -f /etc/rc.local /etc/s6/rc.local
  chmod 755 /etc/s6/rc.local
fi

# OpenRC
if [ -d /etc/runlevels ]; then
  mv -f /etc/rc.local /etc/local.d/rc.start
  chmod 755 /etc/local.d/rc.start
  add_service local

  # On KDE Plasma, rc.local should only run once someone has logged in through sddm into a Plasma session.
  if pacman -Qi plasma-desktop &>/dev/null || pacman -Qi plasma-meta &>/dev/null; then
    if ! head -1 /etc/local.d/rc.start | grep -q "^#!"; then
      sed -i "1i #!/bin/sh" /etc/local.d/rc.start
    fi
    {
      head -1 /etc/local.d/rc.start
      echo "# Wait for an sddm-launched KDE Plasma session to actually start"
      echo "# before running the rest of this script."
      echo "while ! pgrep -x plasmashell >/dev/null 2>&1; do"
      echo "  sleep 1"
      echo "done"
      tail -n +2 /etc/local.d/rc.start
    } > /etc/local.d/rc.start.new
    mv -f /etc/local.d/rc.start.new /etc/local.d/rc.start
    chmod 755 /etc/local.d/rc.start
    echo "KDE Plasma detected: rc.local will now wait for an sddm login before running." >&2
  fi
fi

# systemd
if [ "$INIT_SYSTEM" = "systemd" ] && [ -f /etc/rc.local ]; then
    if ! head -1 /etc/rc.local | grep -q "^#!"; then
        sed -i "1i #!/bin/bash" /etc/rc.local
    fi
    chmod +x /etc/rc.local
    if ! grep -q "^exit 0" /etc/rc.local; then
        echo "" >> /etc/rc.local
        echo "exit 0" >> /etc/rc.local
    fi
cat > /etc/systemd/system/rc-local.service <<EOF
[Unit]
Description=/etc/rc.local Compatibility
Documentation=man:systemd-rc-local-generator(8)
ConditionFileIsExecutable=/etc/rc.local
After=network-online.target
Wants=network-online.target
Before=display-manager.service graphical.target

[Service]
Type=oneshot
ExecStart=/etc/rc.local start
TimeoutSec=0
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    if systemctl enable --now rc-local.service; then
        echo "rc-local.service: enabled and started"
    else
        echo "rc-local.service: FAILED to enable/start" >&2
        systemctl status rc-local.service --no-pager >&2
    fi
fi

# RESET PERMISSIONS
reset-permissions

# HARDENING SCRIPT
hardening-script

# EXIT
cd /
grub-install || true
update-grub
rm -rf /home/ulu-files/
echo -e "\e[ULU has been successfully installed\e[0m"
reboot

elif command -v xbps-install &>/dev/null; then

######################
# VOID LINUX SECTION #
######################

### SERVICE MANAGEMENT FUNCTIONS ###

add_service() {
    local service_name="$1"
    ln -sf "/etc/sv/$service_name" /var/service/
}

remove_service() {
    local service_name="$1"
    sv down "$service_name" &>/dev/null || true
    rm -f "/var/service/$service_name"
}

### INSTALL PACKAGES ONE BY ONE WITH RETRIES ###

careful_install() {
  local failed_packages=()
  for pkg in "$@"; do
    local success=false
    for attempt in $(seq 1 5); do
      echo "Installing $pkg (attempt $attempt/5)..." >&2
      if xbps-install -y "$pkg"; then
        success=true
        break
      else
        if [ "$attempt" -lt 5 ]; then
          echo "Attempt $attempt failed for $pkg, retrying in 5 seconds..." >&2
          sleep 5
        else
          echo "All 5 attempts failed for $pkg, skipping..." >&2
          failed_packages+=("$pkg")
        fi
      fi
    done
  done

  if [ "${#failed_packages[@]}" -gt 0 ]; then
    echo -e "\e[1mThe following packages failed to install and were skipped:\e[0m" >&2
    for pkg in "${failed_packages[@]}"; do
      echo "  - $pkg" >&2
    done
  fi
}

### ULU CHOICE SELECTION ###

echo -e "\e[1mSelect a ULU Variant\e[0m"
echo "1. AMD-DESKTOP"
echo "2. AMD-LAPTOP"
echo "3. INTEL-DESKTOP"
echo "4. INTEL-LAPTOP"
echo "5. NVIDIA-OPENSOURCE-DESKTOP"
echo "6. NVIDIA-PROPRIETARY-DESKTOP"

read -p "Enter your choice (1-6): " choice

### FIRST COMMANDS AND ULU IMPORT P1 ###

xbps-install -Syu 7zip unzip git xbps
mkdir -p /home/ulu-files/
git clone https://github.com/Michael-Sebero/ULU /home/ulu-files/
cd /home/ulu-files/files/ulu-packages/

# ENABLE NONFREE + MULTILIB REPOS (needed for Steam, NVIDIA, 32-bit libs, etc.)
xbps-install -Sy void-repo-nonfree void-repo-multilib void-repo-multilib-nonfree
xbps-install -Sy

### FULL SYSTEM UPDATE WITH RETRIES ###

for attempt in $(seq 1 5); do
  echo "Running full system update (attempt $attempt/5)..." >&2
  if xbps-install -Suy; then
    echo "System update succeeded." >&2
    break
  else
    if [ "$attempt" -lt 5 ]; then
      echo "Attempt $attempt failed, retrying in 5 seconds..." >&2
      sleep 5
    else
      echo "All 5 attempts failed for full system update. Continuing anyway..." >&2
    fi
  fi
done
# xbps sometimes updates itself in a separate transaction; run a second pass for the rest
xbps-install -Suy || true

mv /home/ulu-files/files/ulu-manual/Manual /home/$USER/Desktop/

# REMOVE PACKAGES
for pkg in pulseaudio nvidia390 nvidia470 nvidia470-libs-32bit ModemManager; do
    if xbps-query "$pkg" &>/dev/null; then
        xbps-remove -y "$pkg" || true
    fi
done

# INSTALL BASE PACKAGES
careful_install \
  unrar flatpak tmux \
  gamemode dnscrypt-proxy apparmor \
  clamav ufw gufw macchanger earlyoom \
  wine wine-mono winetricks steam lynis rkhunter opendoas \
  pipewire alsa-pipewire wireplumber \
  rust usbguard chkrootkit alsa-utils expect \
  inotify-tools preload dialog tree parallel sof-firmware Vulkan-Tools mimalloc mold \
  protontricks python3-pip ccache yt-dlp \
  libdisplay-info-32bit gallery-dl tesseract-ocr tesseract-ocr-eng \
  fwupd chrony dnsmasq mesa mesa-32bit tk scx libgamemode-32bit nix

# Headers for the currently running/installed kernel (needed by DKMS drivers like NVIDIA).
KVER=$(uname -r | cut -d. -f1-2)
if [ -n "$KVER" ]; then
  careful_install "linux${KVER}-headers"
fi

# AMD-DESKTOP CHOICE
if [ "$choice" = "1" ]; then
  if xbps-query thunar &>/dev/null; then
    xbps-remove -y xfce4-power-manager xfce4-battery-plugin || true
  fi
  careful_install \
    mesa-vulkan-radeon mesa-vulkan-radeon-32bit libva-utils \
    fail2ban cpupower
fi

# AMD-LAPTOP CHOICE
if [ "$choice" = "2" ]; then
  careful_install \
    mesa-vulkan-radeon mesa-vulkan-radeon-32bit libva-utils \
    tlp blueman bluez brightnessctl
fi

# INTEL-DESKTOP CHOICE
if [ "$choice" = "3" ]; then
  if xbps-query thunar &>/dev/null; then
    xbps-remove -y xfce4-power-manager xfce4-battery-plugin || true
  fi
  careful_install \
    mesa-vulkan-intel mesa-vulkan-intel-32bit libva-utils \
    fail2ban cpupower
fi

# INTEL-LAPTOP CHOICE
if [ "$choice" = "4" ]; then
  careful_install \
    mesa-vulkan-intel mesa-vulkan-intel-32bit libva-utils \
    tlp blueman bluez brightnessctl
fi

# NVIDIA-OPENSOURCE-DESKTOP CHOICE
if [ "$choice" = "5" ]; then
  if xbps-query thunar &>/dev/null; then
    xbps-remove -y xfce4-power-manager xfce4-battery-plugin || true
  fi
  careful_install \
    nvidia nvidia-libs-32bit \
    fail2ban cpupower
fi

# NVIDIA-PROPRIETARY-DESKTOP CHOICE
if [ "$choice" = "6" ]; then
  if xbps-query thunar &>/dev/null; then
    xbps-remove -y xfce4-power-manager xfce4-battery-plugin || true
  fi
  careful_install \
    nvidia580 nvidia580-libs-32bit \
    fail2ban cpupower
fi

# IMPORT FLATPAK BETA REPO
flatpak remote-add flathub-beta https://flathub.org/beta-repo/flathub-beta.flatpakrepo

# INSTALL PROTON-GE
if xbps-query protonup-ng &>/dev/null; then
    su - "$USER" -c "protonup -d /home/$USER/.local/share/Steam/compatibilitytools.d/ && protonup -y"
fi

### ULU INSTALL ###

# AMD/INTEL SELECTION
if [ "$choice" = "1" ] || [ "$choice" = "3" ]; then
  unzip -o ulu-root-main.zip -d /
  unzip -o ulu-root-programs.zip -d /
  add_service fail2ban
  add_service cpupower
fi

# LAPTOP SELECTION
if [ "$choice" = "2" ] || [ "$choice" = "4" ]; then
  unzip -o ulu-root-main.zip -d /
  unzip -o ulu-root-programs.zip -d /
  unzip -o ulu-root-laptop.zip -d /
  add_service tlp
fi

# NVIDIA SELECTION
if [ "$choice" = "5" ] || [ "$choice" = "6" ]; then
  unzip -o ulu-root-main.zip -d /
  unzip -o ulu-root-programs.zip -d /
  unzip -o ulu-nvidia-patch.zip -d /
  add_service fail2ban
  add_service cpupower
fi

### LAST COMMANDS ###

# ADD SERVICES
add_service apparmor
add_service dnscrypt-proxy
add_service dnsmasq
add_service ufw
add_service earlyoom
add_service usbguard

### REMOVE COMPETING NETWORK PACKAGES ###

if xbps-query NetworkManager &>/dev/null; then
    echo "NetworkManager already installed, skipping network package replacement." >&2
else
    careful_install NetworkManager

    # Remove other network management packages now that NetworkManager is in place.
    # Add any additional competing packages to this list as needed.
    OTHER_NETWORK_PKGS=()
    for pkg in connman connman-gtk wicd dhcpcd; do
        xbps-query "$pkg" &>/dev/null && OTHER_NETWORK_PKGS+=("$pkg")
    done
    if [ "${#OTHER_NETWORK_PKGS[@]}" -gt 0 ]; then
        echo "Removing competing network packages: ${OTHER_NETWORK_PKGS[*]}" >&2
        for pkg in "${OTHER_NETWORK_PKGS[@]}"; do
            case "$pkg" in
                connman*)
                    sv down connmand &>/dev/null || true
                    rm -f /var/service/connmand
                    find /etc/sv -maxdepth 1 -iname "*connman*" -print -exec rm -rf {} + || true
                    ;;
                wicd|dhcpcd)
                    remove_service "$pkg"
                    ;;
            esac
        done
        xbps-remove -y "${OTHER_NETWORK_PKGS[@]}" || true
    else
        echo "No competing network packages detected." >&2
    fi
fi

add_service NetworkManager

grub-mkconfig -o /boot/grub/grub.cfg

# CREATE GAMEMODE GROUP
if [ "$choice" = "1" ] || [ "$choice" = "3" ] || [ "$choice" = "5" ] || [ "$choice" = "6" ]; then
  groupadd -f gamemode
  TARGET_USER=$USER
  if [ "$TARGET_USER" = "root" ]; then
    TARGET_USER=$(find /home -mindepth 1 -maxdepth 1 -type d -printf "%f\n" | head -1)
  fi
  usermod -aG gamemode "$TARGET_USER"
  echo "Added user $TARGET_USER to gamemode group"
  if id "$TARGET_USER" | grep -o "gamemode" &>/dev/null; then
    echo "Successfully added to gamemode group"
  else
    echo "Failed to add to gamemode group"
  fi
fi

# ADD USER TO REALTIME
groupadd -f realtime
usermod -aG realtime "$(logname)"

# RESET PERMISSIONS
reset-permissions

# HARDENING SCRIPT
hardening-script

# EXIT
cd /
grub-install || true
rm -rf /home/ulu-files/
echo -e "\e[ULU has been successfully installed\e[0m"
reboot

else

###############################
# DEBIAN/UBUNTU LINUX SECTION #
###############################

### PACKAGE MANAGER / DISTRO DETECTION ###

if ! command -v apt-get &>/dev/null; then
    echo "Unsupported distribution. This section supports Linux Mint and Ubuntu." >&2
    exit 1
fi

### INIT SYSTEM ###

INIT_SYSTEM="systemd"

### SERVICE MANAGEMENT FUNCTIONS ###

add_service() {
    local service_name="$1"
    systemctl enable "$service_name" &>/dev/null || true
}

remove_service() {
    local service_name="$1"
    systemctl disable "$service_name" &>/dev/null || true
}

### PACKAGE NAME MAPPING ###

map_package_names() {
    local base_pkg="$1"
    case "$base_pkg" in
        unrar) echo "unrar" ;;
        flatpak) echo "flatpak" ;;
        gamemode) echo "gamemode" ;;
        lib32-gamemode) echo "libgamemode0:i386" ;;
        dnscrypt-proxy) echo "dnscrypt-proxy" ;;
        dnsmasq) echo "dnsmasq" ;;
        apparmor) echo "apparmor apparmor-utils" ;;
        gufw) echo "gufw" ;;
        macchanger) echo "macchanger" ;;
        wine) echo "wine" ;;
        wine-mono) echo "" ;;
        winetricks) echo "winetricks" ;;
        steam) echo "steam-installer" ;;
        lynis) echo "lynis" ;;
        rkhunter) echo "rkhunter" ;;
        usbguard) echo "usbguard" ;;
        chkrootkit) echo "chkrootkit" ;;
        expect) echo "expect" ;;
        inotify-tools) echo "inotify-tools" ;;
        preload) echo "preload" ;;
        dialog) echo "dialog" ;;
        tree) echo "tree" ;;
        parallel) echo "parallel" ;;
        sof-firmware) echo "firmware-sof-signed" ;;
        booster) echo "" ;;
        vulkan-tools) echo "vulkan-tools" ;;
        mimalloc) echo "libmimalloc2.0" ;;
        mold) echo "mold" ;;
        protontricks) echo "" ;;
        poetry) echo "" ;;
        pyenv) echo "" ;;
        python-pip) echo "python3-pip" ;;
        ccache) echo "ccache" ;;
        yt-dlp) echo "yt-dlp" ;;
        lib32-libdisplay-info) echo "" ;;
        realtime-privileges) echo "" ;;
        gallery-dl) echo "gallery-dl" ;;
        tesseract-data-eng) echo "tesseract-ocr-eng" ;;
        debtap) echo "" ;;
        downgrade) echo "" ;;
        opendoas) echo "doas" ;;
        rust) echo "rustc cargo" ;;
        scx-scheds) echo "" ;;
        fwupd) echo "fwupd" ;;
        chrony) echo "chrony" ;;
        mesa) echo "mesa-utils" ;;
        lib32-mesa) echo "libgl1-mesa-dri:i386" ;;
        tk) echo "tk" ;;
        nix) echo "" ;;
        networkmanager) echo "network-manager" ;;
        seahorse) echo "seahorse" ;;
        ffmpegthumbnailer) echo "ffmpegthumbnailer" ;;
        clamav) echo "clamav clamav-daemon" ;;
        earlyoom) echo "earlyoom" ;;
        fail2ban) echo "fail2ban" ;;
        cpupower) echo "linux-tools-common linux-tools-generic" ;;
        tlp) echo "tlp tlp-rdw" ;;
        throttled) echo "" ;;
        blueman) echo "blueman" ;;
        bluez) echo "bluez" ;;
        brightnessctl) echo "brightnessctl" ;;
        vulkan-driver) echo "mesa-vulkan-drivers" ;;
        lib32-vulkan-driver) echo "mesa-vulkan-drivers:i386" ;;
        *) echo "$base_pkg" ;;
    esac
}

### INSTALL PACKAGES ONE BY ONE WITH RETRIES ###

careful_install_raw() {
    local failed_packages=()
    for pkg in "$@"; do
        local success=false
        for attempt in $(seq 1 5); do
            echo "Installing $pkg (attempt $attempt/5)..." >&2
            if DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$pkg"; then
                success=true
                break
            else
                if [ "$attempt" -lt 5 ]; then
                    echo "Attempt $attempt failed for $pkg, retrying in 5 seconds..." >&2
                    sleep 5
                else
                    echo "All 5 attempts failed for $pkg, skipping..." >&2
                    failed_packages+=("$pkg")
                fi
            fi
        done
    done

    if [ "${#failed_packages[@]}" -gt 0 ]; then
        echo -e "\e[1mThe following packages failed to install and were skipped:\e[0m" >&2
        for pkg in "${failed_packages[@]}"; do
            echo "  - $pkg" >&2
        done
    fi
}

### INSTALL PACKAGES ONE BY ONE WITH RETRIES (canonical Artix/Void-style names) ###

careful_install() {
    local mapped_all=()
    for base_pkg in "$@"; do
        local mapped
        mapped=$(map_package_names "$base_pkg")
        if [ -n "$mapped" ]; then
            mapped_all+=($mapped)
        fi
    done
    if [ "${#mapped_all[@]}" -gt 0 ]; then
        careful_install_raw "${mapped_all[@]}"
    fi
}

### ULU CHOICE SELECTION ###

echo -e "\e[1mSelect a ULU Variant\e[0m"
echo "1. AMD-DESKTOP"
echo "2. AMD-LAPTOP"
echo "3. INTEL-DESKTOP"
echo "4. INTEL-LAPTOP"
echo "5. NVIDIA-OPENSOURCE-DESKTOP"
echo "6. NVIDIA-PROPRIETARY-DESKTOP"

read -p "Enter your choice (1-6): " choice

### INITIAL SETUP & PREREQUISITE TOOLS ###

echo -e "\e[1mUpdating package lists...\e[0m"
export DEBIAN_FRONTEND=noninteractive
dpkg --add-architecture i386
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg wget git unzip p7zip-full software-properties-common apt-transport-https

### ENABLE ADDITIONAL REPOSITORIES ###

echo -e "\e[1mEnabling additional repositories...\e[0m"
if command -v add-apt-repository &>/dev/null; then
    add-apt-repository -y universe 2>/dev/null || true
    add-apt-repository -y multiverse 2>/dev/null || true
fi
apt-get update

### FIRST COMMANDS AND ULU IMPORT P1 ###

mkdir -p /home/ulu-files/
git clone https://github.com/Michael-Sebero/ULU /home/ulu-files/
cd /home/ulu-files/files/ulu-packages/

### FULL SYSTEM UPDATE WITH RETRIES ###

for attempt in $(seq 1 5); do
    echo "Running full system update (attempt $attempt/5)..." >&2
    if DEBIAN_FRONTEND=noninteractive apt-get -y dist-upgrade; then
        echo "System update succeeded." >&2
        break
    else
        if [ "$attempt" -lt 5 ]; then
            echo "Attempt $attempt failed, retrying in 5 seconds..." >&2
            sleep 5
        else
            echo "All 5 attempts failed for full system update. Continuing anyway..." >&2
        fi
    fi
done

mv /home/ulu-files/files/ulu-manual/Manual /home/$USER/Desktop/

### REMOVE CONFLICTING PACKAGES ###

for pkg in pulseaudio pulseaudio-module-bluetooth modemmanager; do
    if dpkg -s "$pkg" &>/dev/null; then
        apt-get purge -y "$pkg" || true
    fi
done

### ENSURE NETWORKMANAGER (REMOVE COMPETING NETWORK PACKAGES) ###

if dpkg -s network-manager &>/dev/null; then
    echo "NetworkManager already installed, skipping network package replacement." >&2
else
    careful_install networkmanager

    # Remove other network management packages now that NetworkManager is in place.
    # Add any additional competing packages to this list as needed.
    OTHER_NETWORK_PKGS=()
    for pkg in connman connman-gtk wicd; do
        dpkg -s "$pkg" &>/dev/null && OTHER_NETWORK_PKGS+=("$pkg")
    done
    if [ "${#OTHER_NETWORK_PKGS[@]}" -gt 0 ]; then
        echo "Removing competing network packages: ${OTHER_NETWORK_PKGS[*]}" >&2
        for pkg in "${OTHER_NETWORK_PKGS[@]}"; do
            case "$pkg" in
                connman*) systemctl disable --now connman &>/dev/null || true ;;
                wicd) systemctl disable --now wicd &>/dev/null || true ;;
            esac
        done
        apt-get purge -y "${OTHER_NETWORK_PKGS[@]}" || true
    else
        echo "No competing network packages detected." >&2
    fi
fi
add_service NetworkManager

### INSTALL BASE PACKAGES ###

careful_install \
  unrar flatpak gamemode lib32-gamemode dnscrypt-proxy apparmor \
  clamav gufw macchanger wine wine-mono winetricks steam lynis rkhunter opendoas \
  rust usbguard chkrootkit expect earlyoom \
  inotify-tools preload dialog tree parallel sof-firmware vulkan-tools mimalloc mold \
  python-pip ccache yt-dlp \
  realtime-privileges gallery-dl tesseract-data-eng \
  fwupd chrony dnsmasq mesa lib32-mesa tk

### INSTALL NIX PACKAGE MANAGER ###

if ! command -v nix &>/dev/null; then
    echo -e "\e[1mInstalling the Nix package manager...\e[0m"
    sh <(curl -L https://nixos.org/nix/install) --daemon --yes || echo "Nix installation failed, skipping." >&2
fi

### INSTALL SCX-SCHEDS (kernel 6.12+ only) ###

check_kernel_version() {
    local kernel_version
    kernel_version=$(uname -r | cut -d. -f1,2)
    local major minor
    major=$(echo "$kernel_version" | cut -d. -f1)
    minor=$(echo "$kernel_version" | cut -d. -f2)
    if [ "$major" -gt 6 ] || { [ "$major" -eq 6 ] && [ "$minor" -ge 12 ]; }; then
        return 0
    else
        return 1
    fi
}

if check_kernel_version; then
    echo "Kernel is 6.12+, but no scx-scheds package is available on apt-based systems; skipping (build it from source if you need it)." >&2
else
    echo "Kernel is below 6.12, skipping scx-scheds installation." >&2
fi

### XANMOD KERNEL HELPER ###

setup_xanmod_repo() {
    if [ -f /etc/apt/sources.list.d/xanmod-release.list ]; then
        return 0
    fi
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://dl.xanmod.org/archive.key | gpg --dearmor -o /etc/apt/keyrings/xanmod-archive-keyring.gpg
    XANMOD_CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
    echo "deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org $XANMOD_CODENAME main" > /etc/apt/sources.list.d/xanmod-release.list
    apt-get update
}

install_xanmod_kernel() {
    local flavor="$1"
    setup_xanmod_repo
    local kernel_pkg="linux-xanmod-x64v3"
    if [ -n "$flavor" ]; then
        kernel_pkg="linux-xanmod-${flavor}-x64v3"
    fi
    careful_install_raw "$kernel_pkg" || careful_install_raw "linux-xanmod-x64v3" || careful_install_raw linux-xanmod
}

# AMD-DESKTOP CHOICE
if [ "$choice" = "1" ]; then
    if command -v thunar &>/dev/null; then
        apt-get purge -y xfce4-power-manager xfce4-battery-plugin || true
    fi
    install_xanmod_kernel edge
    careful_install vulkan-driver lib32-vulkan-driver libva-utils fail2ban cpupower
fi

# AMD-LAPTOP CHOICE
if [ "$choice" = "2" ]; then
    install_xanmod_kernel ""
    careful_install vulkan-driver lib32-vulkan-driver libva-utils tlp blueman bluez brightnessctl
fi

# INTEL-DESKTOP CHOICE
if [ "$choice" = "3" ]; then
    if command -v thunar &>/dev/null; then
        apt-get purge -y xfce4-power-manager xfce4-battery-plugin || true
    fi
    install_xanmod_kernel edge
    careful_install vulkan-driver lib32-vulkan-driver libva-utils fail2ban cpupower
fi

# INTEL-LAPTOP CHOICE
if [ "$choice" = "4" ]; then
    install_xanmod_kernel ""
    careful_install vulkan-driver lib32-vulkan-driver libva-utils tlp blueman bluez brightnessctl
fi

# NVIDIA-OPENSOURCE-DESKTOP CHOICE
if [ "$choice" = "5" ]; then
    if command -v thunar &>/dev/null; then
        apt-get purge -y xfce4-power-manager xfce4-battery-plugin || true
    fi
    install_xanmod_kernel edge
    apt-get install -y --no-install-recommends ubuntu-drivers-common 2>/dev/null || true
    RECOMMENDED_DRIVER=$(ubuntu-drivers devices 2>/dev/null | awk "/recommended/{print \$3}" | head -n1)
    if [ -n "$RECOMMENDED_DRIVER" ]; then
        careful_install_raw "${RECOMMENDED_DRIVER}-open" || careful_install_raw "$RECOMMENDED_DRIVER"
    else
        ubuntu-drivers autoinstall || true
    fi
    careful_install libva-utils fail2ban cpupower
fi

# NVIDIA-PROPRIETARY-DESKTOP CHOICE
if [ "$choice" = "6" ]; then
    if command -v thunar &>/dev/null; then
        apt-get purge -y xfce4-power-manager xfce4-battery-plugin || true
    fi
    install_xanmod_kernel edge
    apt-get install -y --no-install-recommends ubuntu-drivers-common 2>/dev/null || true
    RECOMMENDED_DRIVER=$(ubuntu-drivers devices 2>/dev/null | awk "/recommended/{print \$3}" | head -n1)
    if [ -n "$RECOMMENDED_DRIVER" ]; then
        careful_install_raw "$RECOMMENDED_DRIVER"
    else
        ubuntu-drivers autoinstall || true
    fi
    careful_install libva-utils fail2ban cpupower
fi

### IMPORT FLATHUB + FLATPAK BETA REPOS ###

flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak remote-add --if-not-exists flathub-beta https://flathub.org/beta-repo/flathub-beta.flatpakrepo

### ULU INSTALL ###

# AMD/INTEL SELECTION
if [ "$choice" = "1" ] || [ "$choice" = "3" ]; then
    unzip -o ulu-root-main.zip -d /
    unzip -o ulu-root-programs.zip -d /
    add_service fail2ban
    add_service cpupower
fi

# LAPTOP SELECTION
if [ "$choice" = "2" ] || [ "$choice" = "4" ]; then
    unzip -o ulu-root-main.zip -d /
    unzip -o ulu-root-programs.zip -d /
    unzip -o ulu-root-laptop.zip -d /
    add_service tlp
fi

# NVIDIA SELECTION
if [ "$choice" = "5" ] || [ "$choice" = "6" ]; then
    unzip -o ulu-root-main.zip -d /
    unzip -o ulu-root-programs.zip -d /
    unzip -o ulu-nvidia-patch.zip -d /
    add_service fail2ban
    add_service cpupower
fi

### ADAPT ULU NETWORKMANAGER/DNSMASQ/DNSCRYPT-PROXY CONFIGS FOR APT ###

echo -e "\e[1mAdapting dnscrypt-proxy/dnsmasq/NetworkManager configs for apt...\e[0m"

if [ -L /etc/resolv.conf ]; then
    rm -f /etc/resolv.conf
    unzip -o ulu-root-main.zip etc/resolv.conf -d /
fi

if [ -f /etc/NetworkManager/NetworkManager.conf ]; then
    sed -i "s/^dhcp=dhclient$/dhcp=internal/" /etc/NetworkManager/NetworkManager.conf
fi

if command -v dnscrypt-proxy &>/dev/null && [ -f /etc/dnscrypt-proxy/dnscrypt-proxy.toml ]; then
    DNSCRYPT_VERSION=$(dnscrypt-proxy -version 2>&1 | grep -oP "[0-9]+\.[0-9]+\.[0-9]+" | head -1)
    MAJOR_VERSION=$(echo "$DNSCRYPT_VERSION" | cut -d. -f1)
    MINOR_VERSION=$(echo "$DNSCRYPT_VERSION" | cut -d. -f2)
    if [ "$MAJOR_VERSION" = "2" ] && [ "$MINOR_VERSION" = "0" ]; then
        FIRST_BOOTSTRAP=$(grep "^bootstrap_resolvers" /etc/dnscrypt-proxy/dnscrypt-proxy.toml | grep -oP "[0-9.]+:[0-9]+" | head -1)
        sed -i "/^bootstrap_resolvers/d; /^odoh_servers/d; /^http3/d" /etc/dnscrypt-proxy/dnscrypt-proxy.toml
        sed -i "/^ipv4_servers/a fallback_resolver = \"${FIRST_BOOTSTRAP:-9.9.9.9:53}\"" /etc/dnscrypt-proxy/dnscrypt-proxy.toml
    fi
fi

systemctl disable --now systemd-resolved 2>/dev/null || true
systemctl mask systemd-resolved 2>/dev/null || true

systemctl enable dnscrypt-proxy 2>/dev/null || true
systemctl restart dnscrypt-proxy 2>/dev/null || true
sleep 3
systemctl enable dnsmasq 2>/dev/null || true
systemctl restart dnsmasq 2>/dev/null || true
sleep 2
if command -v nmcli &>/dev/null; then
    systemctl restart NetworkManager 2>/dev/null || true
fi

echo "DNS configuration complete."

### INSTALL UNIVERSAL RC.LOCAL ###

RC_LOCAL_PATH="/etc/rc.local"

if [ -f "$RC_LOCAL_PATH" ]; then
    if ! head -1 "$RC_LOCAL_PATH" | grep -q "^#!"; then
        sed -i "1i #!/bin/bash" "$RC_LOCAL_PATH"
    fi
    chmod +x "$RC_LOCAL_PATH"
    if ! grep -q "^exit 0" "$RC_LOCAL_PATH"; then
        echo "" >> "$RC_LOCAL_PATH"
        echo "exit 0" >> "$RC_LOCAL_PATH"
    fi

cat > /etc/systemd/system/rc-local.service <<EOF
[Unit]
Description=/etc/rc.local Compatibility
Documentation=man:systemd-rc-local-generator(8)
ConditionFileIsExecutable=$RC_LOCAL_PATH
After=network-online.target
Wants=network-online.target
Before=display-manager.service graphical.target

[Service]
Type=oneshot
ExecStart=$RC_LOCAL_PATH start
TimeoutSec=0
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    if systemctl enable --now rc-local.service; then
        echo "rc-local.service: enabled and started"
    else
        echo "rc-local.service: FAILED to enable/start" >&2
        systemctl status rc-local.service --no-pager >&2
    fi
fi

### LAST COMMANDS ###

# ADD SERVICES
add_service apparmor
add_service dnscrypt-proxy
add_service dnsmasq
add_service earlyoom
add_service usbguard
if command -v ufw &>/dev/null; then
    add_service ufw
fi

update-grub 2>/dev/null || true

# CREATE GAMEMODE GROUP
if [ "$choice" = "1" ] || [ "$choice" = "3" ] || [ "$choice" = "5" ] || [ "$choice" = "6" ]; then
    groupadd -f gamemode
    TARGET_USER=$USER
    if [ "$TARGET_USER" = "root" ]; then
        TARGET_USER=$(find /home -mindepth 1 -maxdepth 1 -type d -printf "%f\n" | head -1)
    fi
    usermod -aG gamemode "$TARGET_USER"
    echo "Added user $TARGET_USER to gamemode group"
    if id "$TARGET_USER" | grep -o "gamemode" &>/dev/null; then
        echo "Successfully added to gamemode group"
    else
        echo "Failed to add to gamemode group"
    fi
fi

# ADD USER TO REALTIME
groupadd -f realtime
usermod -aG realtime "$(logname)"

# RESET PERMISSIONS
reset-permissions

# HARDENING SCRIPT
hardening-script

# EXIT
cd /
rm -rf /home/ulu-files/
echo -e "\e[ULU has been successfully installed\e[0m"
reboot

fi
'
