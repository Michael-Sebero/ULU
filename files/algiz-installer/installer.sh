#!/bin/bash

su -c '
### RETRY LOGIC ###
retry() {
  local max_attempts="$1"
  shift
  local command="$@"
  local attempt_num=1
  
  until $command
  do
    if (( attempt_num == max_attempts ))
    then
      echo "Attempt $attempt_num failed! Filtering out unavailable packages and retrying..." >&2
      
      # Extract package names and detect package manager
      local pkg_list=""
      local pkg_manager=""
      local base_flags=""
      
      if echo "$command" | grep -q "paru.*-S"; then
        pkg_manager="paru"
        pkg_list=$(echo "$command" | sed -E "s/.*paru[[:space:]]+(-S[[:space:]]+[^[:space:]]*[[:space:]]+)*(--[^[:space:]]+[[:space:]]+)*//")
        base_flags="-S --noconfirm --needed"
      elif echo "$command" | grep -q "pacman.*-S"; then
        pkg_manager="pacman"
        pkg_list=$(echo "$command" | sed -E "s/.*pacman[[:space:]]+(-S[[:space:]]+[^[:space:]]*[[:space:]]+)*(--[^[:space:]]+[[:space:]]+)*//")
        base_flags="-S --noconfirm --needed --overwrite='*'"
      else
        echo "Unable to detect package manager (paru/pacman) from command, continuing..." >&2
        return 0
      fi
      
      # Extract additional flags (like --ignore)
      local extra_flags=""
      if echo "$command" | grep -q -- "--ignore="; then
        extra_flags=$(echo "$command" | grep -o -- "--ignore=[^ ]*")
      fi
      if echo "$command" | grep -q -- "--overwrite="; then
        local overwrite_flag=$(echo "$command" | grep -o -- "--overwrite=[^ ]*")
        if [[ "$extra_flags" != *"--overwrite="* ]]; then
          extra_flags="$extra_flags $overwrite_flag"
        fi
      fi
      
      # Get list of available packages
      echo "Checking package availability with $pkg_manager..." >&2
      local all_pkgs=($pkg_list)
      local available_pkgs=""
      local unavailable_pkgs=""
      
      for pkg in "${all_pkgs[@]}"; do
        if [ -z "$pkg" ]; then continue; fi
        
        # Check if package exists in repositories
        if $pkg_manager -Si "$pkg" &>/dev/null; then
          available_pkgs="$available_pkgs $pkg"
        else
          unavailable_pkgs="$unavailable_pkgs $pkg"
        fi
      done
      
      # Trim whitespace
      available_pkgs=$(echo "$available_pkgs" | sed "s/^[[:space:]]*//;s/[[:space:]]*$//")
      unavailable_pkgs=$(echo "$unavailable_pkgs" | sed "s/^[[:space:]]*//;s/[[:space:]]*$//")
      
      if [ -n "$unavailable_pkgs" ]; then
        echo "Skipping unavailable packages: $unavailable_pkgs" >&2
      fi
      
      if [ -n "$available_pkgs" ]; then
        # Reconstruct the command with available packages only
        local new_cmd="$pkg_manager $base_flags $extra_flags $available_pkgs"
        echo "Installing available packages: $available_pkgs" >&2
        echo "Executing: $new_cmd" >&2
        
        # Execute the modified command
        eval "$new_cmd" && return 0 || return 1
      else
        echo "No available packages found, skipping installation..." >&2
        return 0
      fi
    else
      echo "Attempt $attempt_num failed! Retrying in 5 seconds..." >&2
      sleep 5
      attempt_num=$(( attempt_num + 1 ))
    fi
  done
}

### ALGIZ LINUX CHOICE SELECTION ###

echo -e "\e[1mSelect a Algiz Linux Variant\e[0m"
echo "1. AMD-DESKTOP"
echo "2. AMD-LAPTOP"
echo "3. INTEL-DESKTOP"
echo "4. INTEL-LAPTOP"
echo "5. NVIDIA-OPENSOURCE-DESKTOP"
echo "6. NVIDIA-PROPRIETARY-DESKTOP"

read -p "Enter your choice (1-6): " choice

# IMPORT KEYS
echo -e "\e[1mImporting repository keys...\e[0m"

curl -s https://raw.githubusercontent.com/chaotic-aur/.github/refs/heads/main/profile/README.md \
| grep -Eo "pacman-key --recv-key [0-9A-F]+" \
| sed "s/--recv-key \([0-9A-F]*\)/--recv-key \1; pacman-key --lsign-key \1/" \
| bash

### FIRST COMMANDS AND ALGIZ-LINUX IMPORT P1 ###
killall xfce4-screensaver || true
pacman -Sy --noconfirm --needed p7zip unzip git base-devel
mkdir /home/algiz-files/
git clone https://github.com/Michael-Sebero/Algiz-Linux /home/algiz-files/
cd /home/algiz-files/files/algiz-packages/
unzip -o algiz-pacman-temp-1.zip -d /etc
pacman -Sy --noconfirm artix-archlinux-support pacman-contrib artix-keyring archlinux-keyring artix-mirrorlist archlinux-mirrorlist
pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'
unzip -o algiz-pacman-temp-2.zip -d /etc
pacman -Sy --noconfirm alhp-keyring alhp-mirrorlist

# CPU ARCHITECTURE DETECTION
arch_support=$(/lib/ld-linux-x86-64.so.2 --help 2>&1 | grep '\''supported'\'' | head -n 1 | awk '\''{print $1}'\'')
if [ "$arch_support" = "x86-64-v3" ]; then
    unzip -o algiz-pacman-v3.zip -d /etc
elif [ "$arch_support" = "x86-64-v4" ]; then
    unzip -o algiz-pacman-v4.zip -d /etc
fi

# TEMP FIX
rm -rf /usr/lib/firmware/nvidia/ad10{3,4,5,6,7} || true && find /etc/pacman.conf -type f -exec sed -i 's/#//g' {} +

# POPULATE & REFRESH
pacman-key --init
pacman-key --populate archlinux artix alhp chaotic
pacman -Syy

# FIND QUICKEST MIRRORLIST
echo -e "\e[1mFinding quickest mirrorlist, please wait...\e[0m"
sh -c "rankmirrors -v -n 4 -m 2 /etc/pacman.d/mirrorlist > /etc/pacman.d/mirrorlist.new && mv /etc/pacman.d/mirrorlist.new /etc/pacman.d/mirrorlist && chmod 644 /etc/pacman.d/mirrorlist"

### FIRST COMMANDS AND ALGIZ-LINUX IMPORT P2 ###
pacman -S paru --noconfirm --needed && retry 5 pacman -Syyu --noconfirm --needed --overwrite='*' --ignore=linux,linux-headers
mv /home/algiz-files/files/algiz-manual/Manual /home/$USER/Desktop/

# REMOVE PACKAGES
paru -Rdd --noconfirm linux linux-headers pulseaudio pulseaudio-alsa pulseaudio-bluetooth pulseaudio-zeroconf artix-branding-base artix-grub-theme mpv mesa vulkan-intel vulkan-radeon vulkan-swrast

# REMOVE XFCE PACKAGES
paru -Rdd --noconfirm epiphany xfce4-screensaver xfce4-terminal xfce4-screenshooter parole xfce4-taskmanager mousepad leafpad xfburn ristretto xfce4-appfinder atril xfce4-sensors-plugin xfce4-notes-plugin xfce4-dict xfce4-weather-plugin || true

# INSTALL BASE PACKAGES
retry 5 paru -S --noconfirm --needed --ignore=vlc,vlc-git,nvidia-390xx-utils,lib32-nvidia-390xx-utils lib32-artix-archlinux-support unrar flatpak kate librewolf tmux liferea ksnip kcalc font-manager pix gimp gamemode lib32-gamemode okular dnscrypt-proxy dnscrypt-proxy-s6 apparmor apparmor-s6 bleachbit konsole catfish clamav clamav-s6 ark gufw macchanger networkmanager networkmanager-s6 nm-connection-editor wine-git wine-mono winetricks-git ufw-s6 steam lynis element-desktop rkhunter appimagelauncher opendoas mate-system-monitor chrony downgrade libreoffice pipewire-pulse pipewire-alsa wireplumber rust usbguard usbguard-s6 chkrootkit wget noto-fonts-emoji tauon-music-box freetube alsa-utils expect inotify-tools preload cpupower cpupower-s6 dialog tree parallel sof-firmware booster bottles vulkan-tools mimalloc mold lld protontricks-git poetry pyenv python-pip hunspell-en_us ccache earlyoom earlyoom-s6 yt-dlp seahorse lib32-libdisplay-info lib32-vulkan-driver mesa-tkg-git lib32-mesa-tkg-git

# INSTALL PYTHON PACKAGES
retry 5 paru -S --noconfirm --needed python-dateutil python-xlib python-psutil python-pyaudio python-pipenv python-matplotlib python-tqdm python-pillow python-mutagen python-magic python-piexif python-moviepy python-brotli python-websockets python-librosa python-audioread python-pypdf2

# INSTALL XFCE PACKAGES
if pacman -Qq | grep -q '^thunar$'; then
    echo "Thunar detected, installing extra XFCE packages..."
    retry 5 paru -S --noconfirm --needed mugshot xfce4-panel-profiles xorg-xrandr redshift lightdm-gtk-greeter-settings gtk-engines xdg-desktop-portal-gtk gtk-engine-murrine
else
    echo "Thunar not detected, skipping XFCE packages."
fi

# AMD/INTEL-DESKTOP CHOICE
if [ "$choice" = "1" ] || [ "$choice" = "3" ]; then
  paru -Rdd --noconfirm xfce4-power-manager xfce4-battery-plugin && retry 5 paru -S --noconfirm --needed linux-cachyos linux-cachyos-headers protonup-git vkbasalt lib32-vkbasalt fail2ban fail2ban-s6
fi

# AMD/INTEL-LAPTOP CHOICE
if [ "$choice" = "2" ] || [ "$choice" = "4" ]; then
  retry 5 paru -S --noconfirm --needed linux-cachyos linux-cachyos-headers throttled tlp tlp-s6 blueman bluez bluez-s6 brightnessctl
fi

# NVIDIA-OPENSOURCE-DESKTOP CHOICE
if [ "$choice" = "5" ]; then
  paru -Rdd --noconfirm xfce4-power-manager xfce4-battery-plugin && retry 5 paru -S --noconfirm --needed linux-cachyos linux-cachyos-headers protonup-git nvidia-utils nvidia-utils-s6 nvidia-settings fail2ban fail2ban-s6 nvidia-open-dkms && paru -S --noconfirm --needed lib32-nvidia-utils || true
fi

# NVIDIA-PROPRIETARY-DESKTOP CHOICE
if [ "$choice" = "6" ]; then
  paru -Rdd --noconfirm xfce4-power-manager xfce4-battery-plugin && retry 5 paru -S --noconfirm --needed linux-cachyos linux-cachyos-headers protonup-git nvidia-utils nvidia-utils-s6 nvidia-settings fail2ban fail2ban-s6 nvidia-dkms && paru -S --noconfirm --needed lib32-nvidia-utils || true
fi

# INSTALL FLATPAK PACKAGES
flatpak remote-add flathub-beta https://flathub.org/beta-repo/flathub-beta.flatpakrepo
flatpak install -y flathub org.kde.haruna

# INSTALL PROTON-GE
if pacman -Q protonup-git &>/dev/null; then
    su - "$USER" -c "protonup -d /home/$USER/.local/share/Steam/compatibilitytools.d/ && protonup -y"
fi

### ALGIZ LINUX INSTALL ###

# AMD/INTEL DESKTOP SELECTION
if [ "$choice" = "1" ] || [ "$choice" = "3" ]; then
  unzip -o algiz-dotfiles.zip -d /home/$USER/
  unzip -o algiz-main.zip -d /
  unzip -o algiz-root.zip -d /
  s6-service add default fail2ban
fi

# LAPTOP SELECTION
if [ "$choice" = "2" ] || [ "$choice" = "4" ]; then
  unzip -o algiz-dotfiles-laptop.zip -d /home/$USER/
  unzip -o algiz-main.zip -d /
  unzip -o algiz-root-laptop.zip -d /
  s6-service add default tlp
fi

# NVIDIA SELECTION
if [ "$choice" = "5" ] || [ "$choice" = "6" ]; then
  unzip -o algiz-dotfiles.zip -d /home/$USER/
  unzip -o algiz-main.zip -d /
  unzip -o algiz-root.zip -d /
  unzip -o algiz-nvidia-patch.zip -d /
  s6-service add default fail2ban
fi

### LAST COMMANDS ###
s6-service add default apparmor
s6-service add default NetworkManager
s6-service add default dnscrypt-proxy
s6-service add default ufw
s6-service add default cpupower
s6-service add default earlyoom

# RESET PERMISSIONS
reset-permissions

# REMOVE CONNMAN & REFRESH
rm /etc/s6/adminsv/default/contents.d/connmand
pacman -Rdd --noconfirm connman connman-s6 connman-gtk
s6-db-reload
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

# HARDENING SCRIPT
sh /algiz/programs/hardening-script/hardening-script.sh && umask 027
cd /

# EXIT
mv /etc/profile{,.old}
grub-install || true
update-grub
rm -rf /home/algiz-files/
echo -e "\e[1mAlgiz Linux has been successfully installed\e[0m"
reboot
'
