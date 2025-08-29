#!/bin/bash

su -c '
### RETRY LOGIC ###

retry_paru() {
  local max_attempts="$1"
  shift
  local command="$@"
  local attempt_num=1
  
  until $command
  do
    if (( attempt_num == max_attempts ))
    then
      echo "Attempt $attempt_num failed! Trying to continue with available packages..." >&2
      
      # Extract package names from the original command
      local pkg_list=""
      if echo "$command" | grep -q " -S "; then
        pkg_list=$(echo "$command" | sed -E "s/.*paru -S[[:space:]]+--noconfirm[[:space:]]+--needed([[:space:]]+--ignore=[^[:space:]]+)?[[:space:]]+//")
      else
        echo "Unable to parse package list from command, continuing..." >&2
        return 0
      fi
      
      # Extract the ignore flag if present
      local ignore_flag=""
      if echo "$command" | grep -q -- "--ignore="; then
        ignore_flag=$(echo "$command" | grep -o -- "--ignore=[^ ]*")
      fi
      
      # Get list of unavailable packages
      echo "Testing package availability, please wait..." >&2
      local all_pkgs=($pkg_list)
      local available_pkgs=""
      local failed_pkgs=""
      
      for pkg in "${all_pkgs[@]}"; do
        if [ -z "$pkg" ]; then continue; fi
        if pacman -Sp "$pkg" &>/dev/null; then
          available_pkgs="$available_pkgs $pkg"
        else
          failed_pkgs="$failed_pkgs $pkg"
        fi
      done
      
      # Trim whitespace
      available_pkgs=$(echo "$available_pkgs" | sed "s/^[[:space:]]*//;s/[[:space:]]*$//")
      failed_pkgs=$(echo "$failed_pkgs" | sed "s/^[[:space:]]*//;s/[[:space:]]*$//")
      
      if [ -n "$failed_pkgs" ]; then
        echo "Skipping unavailable packages: $failed_pkgs" >&2
      fi
      
      if [ -n "$available_pkgs" ]; then
        # Reconstruct the command with available packages
        local new_cmd="pacman -S --noconfirm --needed --overwrite='*' $ignore_flag $available_pkgs"
        echo "Executing modified command: $new_cmd" >&2
        
        # Execute the modified command
        eval $new_cmd && return 0 || return 1
      else
        echo "No available packages found, continuing..." >&2
        return 0
      fi
    else
      echo "Attempt $attempt_num failed! Retrying in 5 seconds..." >&2
      sleep 5
      attempt_num=$(( attempt_num + 1 ))
    fi
  done
}

### COOLRUNE CHOICE SELECTION ###

echo -e "\e[1mSelect a CoolRune Variant\e[0m"
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

### FIRST COMMANDS AND COOLRUNE IMPORT P1 ###
killall xfce4-screensaver
pacman -Sy --noconfirm --needed p7zip unzip git base-devel
mkdir /home/coolrune-files/
git clone https://github.com/Michael-Sebero/CoolRune /home/coolrune-files/
cd /home/coolrune-files/files/coolrune-packages/
unzip -o coolrune-pacman-temp-1.zip -d /etc
pacman -Sy --noconfirm artix-archlinux-support pacman-contrib artix-keyring archlinux-keyring artix-mirrorlist archlinux-mirrorlist
pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'
unzip -o coolrune-pacman-temp-2.zip -d /etc
pacman -Sy --noconfirm alhp-keyring alhp-mirrorlist

# CPU ARCHITECTURE DETECTION
arch_support=$(/lib/ld-linux-x86-64.so.2 --help 2>&1 | grep '\''supported'\'' | head -n 1 | awk '\''{print $1}'\'')
if [ "$arch_support" = "x86-64-v3" ]; then
    unzip -o coolrune-pacman-v3.zip -d /etc
elif [ "$arch_support" = "x86-64-v4" ]; then
    unzip -o coolrune-pacman-v4.zip -d /etc
fi

# TEMP FIX
rm -rf /usr/lib/firmware/nvidia/ad10{3,4,5,6,7} || true && find /etc/pacman.conf -type f -exec sed -i 's/#//g' {} +

# POPULATE & REFRESH
pacman-key --init
pacman-key --populate archlinux artix alhp chaotic
pacman -Syy

# FIND QUICKEST MIRRORLIST
echo -e "\e[1mFinding quickest mirrorlist, please wait...\e[0m"
sh -c "rankmirrors -v -n 5 -m 2 /etc/pacman.d/mirrorlist > /etc/pacman.d/mirrorlist.new && mv /etc/pacman.d/mirrorlist.new /etc/pacman.d/mirrorlist && chmod 644 /etc/pacman.d/mirrorlist"

### FIRST COMMANDS AND COOLRUNE IMPORT P2 ###
pacman -S paru --noconfirm --needed && retry_paru 5 paru -Syyu --noconfirm --needed --overwrite='*' --ignore=linux,linux-headers
mv /home/coolrune-files/files/coolrune-manual/Manual /home/$USER/Desktop/

# REPO PACKAGES REMOVE
paru -Rdd --noconfirm linux linux-headers pulseaudio pulseaudio-alsa pulseaudio-bluetooth pulseaudio-zeroconf epiphany xfce4-screensaver xfce4-terminal xfce4-screenshooter parole xfce4-taskmanager mousepad leafpad xfburn ristretto xfce4-appfinder atril artix-branding-base artix-grub-theme xfce4-sensors-plugin xfce4-notes-plugin mpv xfce4-dict xfce4-weather-plugin mesa vulkan-intel vulkan-radeon vulkan-swrast

# INSTALL REPO PACKAGES
retry_paru 5 paru -S --noconfirm --needed --overwrite='*' --ignore=vlc,vlc-git,nvidia-390xx-utils,lib32-nvidia-390xx-utils lib32-artix-archlinux-support xorg-xrandr unrar flatpak kate librewolf python-pip tmux liferea ksnip kcalc font-manager pix gimp gamemode lib32-gamemode okular dnscrypt-proxy dnscrypt-proxy-s6 apparmor apparmor-s6 bleachbit konsole catfish clamav clamav-s6 ark gufw mugshot macchanger networkmanager networkmanager-s6 nm-connection-editor wine-git wine-mono winetricks-git ufw-s6 redshift steam lynis element-desktop rkhunter appimagelauncher opendoas mate-system-monitor chrony lightdm-gtk-greeter-settings downgrade libreoffice pipewire-pulse pipewire-alsa wireplumber rust python-psutil python-dateutil python-xlib python-pyaudio python-pipenv usbguard usbguard-s6 hunspell-en_us chkrootkit python-matplotlib python-tqdm python-pillow python-mutagen wget noto-fonts-emoji xfce4-panel-profiles poetry tauon-music-box yt-dlp pyenv freetube python-magic python-piexif alsa-utils jq expect inotify-tools preload python-moviepy python-brotli python-websockets cpupower cpupower-s6 python-librosa python-audioread ccache earlyoom earlyoom-s6 python-pypdf2 dialog tree parallel sof-firmware booster bottles vulkan-tools mimalloc mold lld mesa-tkg-git lib32-mesa-tkg-git gtk-engines xdg-desktop-portal-gtk protontricks-git

# AMD/INTEL-DESKTOP CHOICE
if [ "$choice" = "1" ] || [ "$choice" = "3" ]; then
  paru -Rdd --noconfirm xfce4-power-manager xfce4-battery-plugin && retry_paru 5 paru -S --noconfirm --needed --overwrite='*' linux-cachyos linux-cachyos-headers protonup-git vkbasalt lib32-vkbasalt fail2ban fail2ban-s6
fi

# AMD/INTEL-LAPTOP CHOICE
if [ "$choice" = "2" ] || [ "$choice" = "4" ]; then
  retry_paru 5 paru -S --noconfirm --needed --overwrite='*' linux-cachyos linux-cachyos-headers throttled tlp tlp-s6 blueman bluez bluez-s6 brightnessctl
fi

# NVIDIA-OPENSOURCE-DESKTOP CHOICE
if [ "$choice" = "5" ]; then
  paru -Rdd --noconfirm xfce4-power-manager xfce4-battery-plugin && retry_paru 5 paru -S --noconfirm --needed --overwrite='*' linux-cachyos linux-cachyos-headers protonup-git nvidia-utils nvidia-utils-s6 lib32-nvidia-utils nvidia-settings fail2ban fail2ban-s6 nvidia-open-dkms
fi

# NVIDIA-PROPRIETARY-DESKTOP CHOICE
if [ "$choice" = "6" ]; then
  paru -Rdd --noconfirm xfce4-power-manager xfce4-battery-plugin && retry_paru 5 paru -S --noconfirm --needed --overwrite='*' linux-cachyos linux-cachyos-headers protonup-git nvidia-utils nvidia-utils-s6 lib32-nvidia-utils nvidia-settings fail2ban fail2ban-s6 nvidia-dkms
fi

# INSTALL FLATPAK PACKAGES
flatpak remote-add flathub-beta https://flathub.org/beta-repo/flathub-beta.flatpakrepo
flatpak install -y org.gnome.seahorse.Application/x86_64/stable org.kde.haruna org.jdownloader.JDownloader

# INSTALL PROTON-GE
if pacman -Q protonup-git &>/dev/null; then
    su - "$USER" -c "protonup -d /home/$USER/.local/share/Steam/compatibilitytools.d/ && protonup -y"
fi

### COOLRUNE INSTALL ###

# AMD/INTEL DESKTOP SELECTION
if [ "$choice" = "1" ] || [ "$choice" = "3" ]; then
  7z x coolrune-dotfiles.7z -o/home/$USER/ -y
  unzip -o coolrune-main.zip -d /
  unzip -o coolrune-root.zip -d /
  s6-service add default fail2ban
fi

# LAPTOP SELECTION
if [ "$choice" = "2" ] || [ "$choice" = "4" ]; then
  7z x coolrune-dotfiles-laptop.7z -o/home/$USER/ -y
  unzip -o coolrune-main.zip -d /
  unzip -o coolrune-root-laptop.zip -d /
  s6-service add default tlp
fi

# NVIDIA SELECTION
if [ "$choice" = "5" ] || [ "$choice" = "6" ]; then
  7z x coolrune-dotfiles.7z -o/home/$USER/ -y
  unzip -o coolrune-main.zip -d /
  unzip -o coolrune-root.zip -d /
  unzip -o coolrune-nvidia-patch.zip -d /
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
sh /CoolRune/Programs/Hardening-Script/hardening-script.sh && umask 027
cd /

# EXIT
mv /etc/profile{,.old}
grub-install || true
update-grub
rm -rf /home/coolrune-files/
echo -e "\e[1mCoolRune has been successfully installed\e[0m"
reboot
'
