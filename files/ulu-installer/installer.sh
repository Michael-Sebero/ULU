#!/bin/bash

su -c '

### ULU PACKAGE INSTALLATION ###

ULU_PKG_DIR="/home/ulu-files/files/ulu-packages"

replace_file() {
    local src="$1" dest="$2" mode="$3"
    local was_immutable=0 installed=0

    if [ -f "$dest" ] && [ ! -L "$dest" ] && lsattr -d "$dest" 2>/dev/null | grep -q "^....i"; then
        was_immutable=1
        chattr -i "$dest" 2>/dev/null || true
    fi

    if install -D -T -m "$mode" "$src" "$dest"; then
        installed=1
    fi

    if [ "$was_immutable" -eq 1 ]; then
        chattr +i "$dest" 2>/dev/null || true
    fi

    [ "$installed" -eq 1 ] && [ -f "$dest" ] && [ ! -L "$dest" ] && cmp -s "$src" "$dest"
}

FAILED_FILES=()
REPLACED_COUNT=0

install_ulu_package() {
    local pkg_dir="$ULU_PKG_DIR/$1"
    local target="$pkg_dir${2:+/$2}"
    local src rel mode
    local count=0

    if [ ! -e "$target" ]; then
        echo "Error: $target does not exist." >&2
        FAILED_FILES+=("package $1 (missing from the downloaded files)")
        return 0
    fi

    echo -e "\e[1mInstalling $1...\e[0m"
    while IFS= read -r -d "" src; do
        rel="${src#"$pkg_dir"/}"
        mode=$(stat -c "%a" "$src")
        case "$rel" in
            bin/*) mode=755 ;;
        esac
        if replace_file "$src" "/$rel" "$mode"; then
            count=$((count + 1))
        else
            echo "Error: failed to replace /$rel" >&2
            FAILED_FILES+=("/$rel")
        fi
    done < <(find "$target" -type f -print0)

    REPLACED_COUNT=$((REPLACED_COUNT + count))
    echo "  $count files replaced and verified"
    return 0
}

# Called after the package installs: every file must be replaced and verified
# before the installer goes any further.
check_ulu_install() {
    local f

    if [ "${#FAILED_FILES[@]}" -gt 0 ]; then
        echo -e "\e[1mThe following files could NOT be replaced:\e[0m" >&2
        for f in "${FAILED_FILES[@]}"; do
            echo "  - $f" >&2
        done
        echo "Installation stopped before the remaining services, bootloader, hardening and reboot. Fix the problem and run the installer again." >&2
        cd /
        rm -rf /home/ulu-files/
        exit 1
    fi
    echo "All $REPLACED_COUNT files replaced and verified."
}

ULU_EXTERNAL_TOOLS=(
    "Package-Dictionary:pd"
    "SCX-IMPERATOR:scx_imperator"
    "SCX-AURA:scx_aura"
    "Linux-Hardening-Script:hardening-script"
    "Ephemeral-Overlay:ephemeral-overlay"
    "Steal:steal"
)

install_ulu_external_tools() {
    local entry repo file attempt cloned tmp
    local failed_tools=()

    tmp=$(mktemp -d) || return 1

    for entry in "${ULU_EXTERNAL_TOOLS[@]}"; do
        repo="${entry%%:*}"
        file="${entry#*:}"
        cloned=false

        for attempt in $(seq 1 5); do
            echo "Cloning $repo (attempt $attempt/5)..." >&2
            rm -rf "$tmp/$repo"
            if GIT_TERMINAL_PROMPT=0 git clone --depth 1 "https://github.com/Michael-Sebero/$repo" "$tmp/$repo"; then
                cloned=true
                break
            fi
            if [ "$attempt" -lt 5 ]; then
                echo "Attempt $attempt failed for $repo, retrying in 5 seconds..." >&2
                sleep 5
            fi
        done

        # The mode is set explicitly: hardening-script is committed without the executable bit.
        if [ "$cloned" = true ] && replace_file "$tmp/$repo/$file" "/bin/$file" 755; then
            echo "Installed /bin/$file"
        else
            echo "Failed to install $file from $repo, skipping..." >&2
            failed_tools+=("$file")
        fi
    done

    rm -rf "$tmp"

    if [ "${#failed_tools[@]}" -gt 0 ]; then
        echo -e "\e[1mThe following tools failed to install and were skipped:\e[0m" >&2
        for file in "${failed_tools[@]}"; do
            echo "  - $file" >&2
        done
        return 1
    fi
}

### ENCRYPTED / LVM / RAID ROOTS ###

# boot-params works out what the initramfs needs to mount / (LUKS, LVM, mdraid,
# btrfs subvolume), updates /etc/booster.yaml and writes /etc/default/grub.local,
# which every ULU /etc/default/grub sources last
BOOT_PARAMS="$ULU_PKG_DIR/ulu-root-programs/bin/boot-params"
STORAGE_OK=true

run_boot_params() {
    if ! bash "$BOOT_PARAMS"; then
        STORAGE_OK=false
        echo "Warning: booster cannot open this root filesystem; the current initramfs generator stays in place." >&2
    fi
}

# Only keep a booster image that can open the root filesystem
booster_image_ok() {
    [ "$STORAGE_OK" = true ] && bash "$BOOT_PARAMS" --check "$1" "$2" >/dev/null
}

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
    if [ "$(ps -p 1 -o comm= 2>/dev/null)" = "dinit" ]; then
        echo "dinit"
        return
    fi
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
    local installer=(pacman -S)
    pacman -Si "$pkg" &>/dev/null || installer=(paru -S)
    for attempt in $(seq 1 5); do
      echo "Installing $pkg (attempt $attempt/5)..." >&2
      if "${installer[@]}" --noconfirm --needed "$pkg"; then
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

### LIMINE CONFIGURATION ###

install_limine() {
    local label

    # limine-sync reads the kernel cmdline and timeout from /etc/default/grub on every run
    if ! grep -q "^GRUB_CMDLINE_LINUX" /etc/default/grub 2>/dev/null; then
        echo "Warning: no GRUB_CMDLINE_LINUX in /etc/default/grub, skipping Limine setup." >&2
        return 1
    fi
    label="Limine"

    local bootsrc
    bootsrc=$(findmnt -no SOURCE --target /boot 2>/dev/null); bootsrc=${bootsrc%%\[*}
    if lsblk -nrso TYPE "$bootsrc" 2>/dev/null | grep -qx crypt; then
        echo "Warning: /boot is encrypted, and Limine would copy the kernel and initramfs to the unencrypted boot partition. Keeping GRUB (cryptodisk) as the bootloader." >&2
        return 1
    fi
    local rootuuid cmdline ldir
    rootuuid=$(findmnt -no UUID --target /)
    cmdline="root=UUID=$rootuuid rw"

    if [ -d /sys/firmware/efi ]; then
        # ================= UEFI: register an NVRAM boot entry =================
        careful_install efibootmgr

        local esp espdev espfstype
        esp=$(findmnt -no TARGET --target /boot/efi 2>/dev/null || findmnt -no TARGET --target /efi 2>/dev/null || findmnt -no TARGET --target /boot)
        espdev=$(findmnt -no SOURCE --target "$esp")
        espfstype=$(blkid -p -o value -s TYPE "$espdev" 2>/dev/null)
        if [ "$espfstype" != "vfat" ]; then
            echo "Warning: the ESP at $esp ($espdev) is $espfstype, not vfat/FAT32 as UEFI firmware requires. Skipping Limine and keeping GRUB, which already boots this system fine, as the sole bootloader." >&2
            return 1
        fi
        ldir="$esp/EFI/limine"

        cat > /usr/local/bin/limine-sync <<SYNC
#!/bin/bash
set -euo pipefail
shopt -s nullglob
GRUB_TIMEOUT=3 GRUB_CMDLINE_LINUX_DEFAULT="" GRUB_CMDLINE_LINUX=""
[ -r /etc/default/grub ] && . /etc/default/grub
case " \$GRUB_CMDLINE_LINUX " in
    *" rd.luks.key="*) echo "limine-sync: FAIL: the initramfs carries a LUKS keyfile; not copying it to the unencrypted boot partition" >&2; exit 1 ;;
esac
mkdir -p "$ldir"
install -Dm755 /usr/share/limine/BOOTX64.EFI "$ldir/BOOTX64.EFI"
install -Dm755 /usr/share/limine/BOOTX64.EFI "$esp/EFI/BOOT/BOOTX64.EFI"
booster_for() {
    local y
    y=\$(booster cat "\$1" etc/booster.init.yaml 2>/dev/null) || return 1
    grep -qxF "kernel: \$2" < <(printf "%s\n" "\$y" | tr -d "\047\"")
}
build_booster() {
    local v="\$1" out="\$2" avail m keep="" dropped="" cfg
    if (umask 0077; booster build --force --kernel-version "\$v" "\$out.new") >&2; then mv -f "\$out.new" "\$out"; return 0; fi
    rm -f "\$out.new"
    avail=\$(sed -e "s/:.*//" "/usr/lib/modules/\$v/modules.dep" "/usr/lib/modules/\$v/modules.builtin" 2>/dev/null | sed -e "s|.*/||" -e "s/\.ko.*//" | tr - _) || true
    for m in \$(sed -n "s/^modules_force_load://p" /etc/booster.yaml | tr "," " "); do
        if grep -qxF "\${m//-/_}" <<< "\$avail"; then keep+="\$m,"; else dropped+=" \$m"; fi
    done
    [ -n "\$dropped" ] || return 1
    cfg=\$(mktemp)
    sed "/^modules_force_load:/d" /etc/booster.yaml > "\$cfg"
    if [ -n "\$keep" ]; then echo "modules_force_load: \${keep%,}" >> "\$cfg"; fi
    echo "limine-sync: kernel \$v lacks force-loaded module(s):\$dropped; building its booster image without them" >&2
    if (umask 0077; booster build --force --config "\$cfg" --kernel-version "\$v" "\$out.new") >&2; then mv -f "\$out.new" "\$out"; rm -f "\$cfg"; return 0; fi
    rm -f "\$out.new" "\$cfg"
    return 1
}
stage() {
    cmp -s "\$1" "$ldir/\${1##*/}" || cp -f "\$1" "$ldir/"
    keep+="\${1##*/} "
}
n=0
skipped=""
keep=" "
{
    echo "timeout: \${GRUB_TIMEOUT:-3}"
    while read -r m; do
        [ -f "\$m" ] || continue
        read -r p < "\$m" || [ -n "\$p" ]
        v="\${m%/pkgbase}"; v="\${v##*/}"
        k="/boot/vmlinuz-\$p"; i="/boot/booster-\$p.img"; label="\$p"
        [ -f "\$k" ] || continue
        if ! booster_for "\$i" "\$v" && [ -d "/usr/lib/modules/\$v" ]; then
            build_booster "\$v" "\$i" || true
        fi
        if ! booster_for "\$i" "\$v"; then
            skipped+=" \$label"
            continue
        fi
        stage "\$k"
        stage "\$i"
        n=\$((n + 1))
        printf "\n/Linux (%s)\n    protocol: linux\n    path: boot():/EFI/limine/%s\n    cmdline: %s\n" "\$label" "\${k##*/}" "$cmdline \$GRUB_CMDLINE_LINUX_DEFAULT \$GRUB_CMDLINE_LINUX"
        for u in amd-ucode.img intel-ucode.img; do
            if [ -f "/boot/\$u" ]; then
                stage "/boot/\$u"
                echo "    module_path: boot():/EFI/limine/\$u"
            fi
        done
        echo "    module_path: boot():/EFI/limine/\${i##*/}"
    done < <(printf "%s\n" /usr/lib/modules/*/pkgbase | sort -rV)
} > "$ldir/limine.conf.new"
if [ "\$n" -eq 0 ]; then
    rm -f "$ldir/limine.conf.new"
    echo "limine-sync: FAIL: no kernel has a booster initramfs built for it; $ldir/limine.conf left unchanged" >&2
    exit 1
fi
mv -f "$ldir/limine.conf.new" "$ldir/limine.conf"
for f in "$ldir"/vmlinuz-* "$ldir"/booster-*.img "$ldir"/*-ucode.img; do
    case "\$keep" in *" \${f##*/} "*) ;; *) rm -f "\$f" ;; esac
done
if [ -n "\$skipped" ]; then
    echo "limine-sync: FAIL: no booster initramfs for:\$skipped (left out of $ldir/limine.conf; \$n entries written)" >&2
else
    echo "limine-sync: PASS: \$n Limine entries, each with a booster initramfs built for its kernel"
fi
SYNC
        chmod +x /usr/local/bin/limine-sync
        if ! /usr/local/bin/limine-sync; then
            echo "Warning: limine-sync failed while staging Limine files to $ldir. Skipping NVRAM entry; GRUB remains the sole bootloader." >&2
            return 1
        fi

        if [ ! -f "$ldir/BOOTX64.EFI" ] || [ ! -f "$esp/EFI/BOOT/BOOTX64.EFI" ] || [ ! -s "$ldir/limine.conf" ]; then
            echo "Warning: limine-sync ran but BOOTX64.EFI and/or limine.conf are missing under $esp. Skipping NVRAM entry; GRUB remains the sole bootloader." >&2
            return 1
        fi

        local dev disk part
        dev="$espdev"
        disk="/dev/$(lsblk -no PKNAME "$dev")"
        part=$(cat "/sys/class/block/$(basename "$dev")/partition")

        if ! efibootmgr | grep -q "$label"; then
            if ! efibootmgr --create --disk "$disk" --part "$part" --label "$label" --loader "\EFI\limine\BOOTX64.EFI" --unicode >/dev/null; then
                echo "Warning: efibootmgr --create failed for label \"$label\" on $disk part $part. Boot files are staged at $ldir but no NVRAM entry exists; GRUB remains the sole bootloader." >&2
                return 1
            fi
        fi

        local bootnum current_order new_order
        bootnum=$(efibootmgr | grep -F "$label" | grep -oE "^Boot[0-9A-Fa-f]{4}" | sed "s/^Boot//" | head -n1)
        if [ -n "$bootnum" ]; then
            current_order=$(efibootmgr | grep "^BootOrder:" | cut -d" " -f2)
            new_order="$bootnum,$(printf "%s" "$current_order" | tr "," "\n" | grep -vx "$bootnum" | paste -sd, -)"
            efibootmgr -o "${new_order%,}" >/dev/null || echo "Warning: could not set BootOrder to pin \"$label\" first; check efibootmgr output." >&2
        else
            echo "Warning: could not find the \"$label\" boot entry to pin it first; check efibootmgr output." >&2
        fi

        # ---- Verify the UEFI installation actually took ----
        if efibootmgr | grep -q "$label" && [ -f "$ldir/BOOTX64.EFI" ] && [ -f "$esp/EFI/BOOT/BOOTX64.EFI" ]; then
            echo "Verified: Limine installed at $ldir (UEFI, label: $label), NVRAM entry present. GRUB remains fully intact as a fallback boot entry."
        else
            echo "Warning: post-install verification failed for UEFI Limine setup (label \"$label\"). Check efibootmgr output and files under $esp." >&2
        fi
    else
        # ================= BIOS/legacy: write Limine into the MBR =================
        local bootmnt bootdev disk name typ fstype fatpart="" fatmnt
        bootmnt=$(findmnt -no TARGET --target /boot 2>/dev/null); [ -n "$bootmnt" ] || bootmnt=/
        bootdev=$(findmnt -no SOURCE --target "$bootmnt"); bootdev=${bootdev%%\[*}
        disk=""
        while read -r name typ; do
            if [ "$typ" = disk ]; then
                disk="/dev/$name"
                break
            fi
        done < <(lsblk -nrso NAME,TYPE "$bootdev")

        while read -r name typ; do
            [ "$typ" = "part" ] || continue
            fstype=$(blkid -p -o value -s TYPE "/dev/$name" 2>/dev/null)
            if [ "$fstype" = "vfat" ]; then
                fatpart="$name"
                break
            fi
        done < <(lsblk -rno NAME,TYPE "$disk")

        if [ -z "$fatpart" ]; then
            echo "Warning: no FAT partition found on $disk. The Limine BIOS boot stage only reads FAT12/16/32 (or ISO9660), and the boot filesystem on this system does not qualify. Skipping Limine and keeping GRUB, which already boots this filesystem fine, as the sole bootloader." >&2
            return 1
        fi

        fatmnt=$(findmnt -no TARGET "/dev/$fatpart" 2>/dev/null)
        if [ -z "$fatmnt" ]; then
            fatmnt=/boot/limine-boot
            mkdir -p "$fatmnt"
            mount "/dev/$fatpart" "$fatmnt"
            if ! grep -q "[[:space:]]${fatmnt}[[:space:]]" /etc/fstab 2>/dev/null; then
                local fatuuid
                fatuuid=$(blkid -p -o value -s UUID "/dev/$fatpart" 2>/dev/null)
                [ -n "$fatuuid" ] && echo "UUID=$fatuuid $fatmnt vfat defaults,noatime 0 2" >> /etc/fstab
            fi
        fi
        ldir="$fatmnt/limine"

        cat > /usr/local/bin/limine-sync <<SYNC
#!/bin/bash
set -euo pipefail
shopt -s nullglob
GRUB_TIMEOUT=3 GRUB_CMDLINE_LINUX_DEFAULT="" GRUB_CMDLINE_LINUX=""
[ -r /etc/default/grub ] && . /etc/default/grub
case " \$GRUB_CMDLINE_LINUX " in
    *" rd.luks.key="*) echo "limine-sync: FAIL: the initramfs carries a LUKS keyfile; not copying it to the unencrypted boot partition" >&2; exit 1 ;;
esac
mkdir -p "$ldir"
install -Dm644 /usr/share/limine/limine-bios.sys "$ldir/limine-bios.sys"
booster_for() {
    local y
    y=\$(booster cat "\$1" etc/booster.init.yaml 2>/dev/null) || return 1
    grep -qxF "kernel: \$2" < <(printf "%s\n" "\$y" | tr -d "\047\"")
}
build_booster() {
    local v="\$1" out="\$2" avail m keep="" dropped="" cfg
    if (umask 0077; booster build --force --kernel-version "\$v" "\$out.new") >&2; then mv -f "\$out.new" "\$out"; return 0; fi
    rm -f "\$out.new"
    avail=\$(sed -e "s/:.*//" "/usr/lib/modules/\$v/modules.dep" "/usr/lib/modules/\$v/modules.builtin" 2>/dev/null | sed -e "s|.*/||" -e "s/\.ko.*//" | tr - _) || true
    for m in \$(sed -n "s/^modules_force_load://p" /etc/booster.yaml | tr "," " "); do
        if grep -qxF "\${m//-/_}" <<< "\$avail"; then keep+="\$m,"; else dropped+=" \$m"; fi
    done
    [ -n "\$dropped" ] || return 1
    cfg=\$(mktemp)
    sed "/^modules_force_load:/d" /etc/booster.yaml > "\$cfg"
    if [ -n "\$keep" ]; then echo "modules_force_load: \${keep%,}" >> "\$cfg"; fi
    echo "limine-sync: kernel \$v lacks force-loaded module(s):\$dropped; building its booster image without them" >&2
    if (umask 0077; booster build --force --config "\$cfg" --kernel-version "\$v" "\$out.new") >&2; then mv -f "\$out.new" "\$out"; rm -f "\$cfg"; return 0; fi
    rm -f "\$out.new" "\$cfg"
    return 1
}
stage() {
    cmp -s "\$1" "$ldir/\${1##*/}" || cp -f "\$1" "$ldir/"
    keep+="\${1##*/} "
}
n=0
skipped=""
keep=" "
{
    echo "timeout: \${GRUB_TIMEOUT:-3}"
    while read -r m; do
        [ -f "\$m" ] || continue
        read -r p < "\$m" || [ -n "\$p" ]
        v="\${m%/pkgbase}"; v="\${v##*/}"
        k="/boot/vmlinuz-\$p"; i="/boot/booster-\$p.img"; label="\$p"
        [ -f "\$k" ] || continue
        if ! booster_for "\$i" "\$v" && [ -d "/usr/lib/modules/\$v" ]; then
            build_booster "\$v" "\$i" || true
        fi
        if ! booster_for "\$i" "\$v"; then
            skipped+=" \$label"
            continue
        fi
        stage "\$k"
        stage "\$i"
        n=\$((n + 1))
        printf "\n/Linux (%s)\n    protocol: linux\n    path: boot():/limine/%s\n    cmdline: %s\n" "\$label" "\${k##*/}" "$cmdline \$GRUB_CMDLINE_LINUX_DEFAULT \$GRUB_CMDLINE_LINUX"
        for u in amd-ucode.img intel-ucode.img; do
            if [ -f "/boot/\$u" ]; then
                stage "/boot/\$u"
                echo "    module_path: boot():/limine/\$u"
            fi
        done
        echo "    module_path: boot():/limine/\${i##*/}"
    done < <(printf "%s\n" /usr/lib/modules/*/pkgbase | sort -rV)
} > "$ldir/limine.conf.new"
if [ "\$n" -eq 0 ]; then
    rm -f "$ldir/limine.conf.new"
    echo "limine-sync: FAIL: no kernel has a booster initramfs built for it; $ldir/limine.conf left unchanged" >&2
    exit 1
fi
mv -f "$ldir/limine.conf.new" "$ldir/limine.conf"
for f in "$ldir"/vmlinuz-* "$ldir"/booster-*.img "$ldir"/*-ucode.img; do
    case "\$keep" in *" \${f##*/} "*) ;; *) rm -f "\$f" ;; esac
done
if [ -n "\$skipped" ]; then
    echo "limine-sync: FAIL: no booster initramfs for:\$skipped (left out of $ldir/limine.conf; \$n entries written)" >&2
else
    echo "limine-sync: PASS: \$n Limine entries, each with a booster initramfs built for its kernel"
fi
SYNC
        chmod +x /usr/local/bin/limine-sync
        if ! /usr/local/bin/limine-sync; then
            echo "Warning: limine-sync found no kernel with a booster initramfs. Skipping limine bios-install; GRUB stays in the MBR." >&2
            return 1
        fi

        local pttype biospart="" ptype biospartnum
        pttype=$(blkid -p -o value -s PTTYPE "$disk" 2>/dev/null)
        if [ "$pttype" = "gpt" ]; then
            while read -r name typ; do
                [ "$typ" = "part" ] || continue
                ptype=$(blkid -p -o value -s PART_ENTRY_TYPE "/dev/$name" 2>/dev/null | tr "[:upper:]" "[:lower:]")
                if [ "$ptype" = "21686148-6449-6e6f-744e-656564454649" ]; then
                    biospart="$name"
                    break
                fi
            done < <(lsblk -rno NAME,TYPE "$disk")
        fi

        if [ -n "$biospart" ]; then
            biospartnum=$(blkid -p -o value -s PART_ENTRY_NUMBER "/dev/$biospart" 2>/dev/null)
            limine bios-install "$disk" "$biospartnum" || echo "Warning: limine bios-install failed on $disk (bios_grub partition $biospartnum)." >&2
        elif [ "$pttype" = "gpt" ]; then
            limine bios-install "$disk" || echo "Warning: limine bios-install failed on $disk. This GPT disk has no spare bios_grub-type partition (GUID 21686148-6449-6E6F-744E-656564454649, 32KiB+) and embedding into GPT structures did not succeed either; create one and re-run." >&2
        else
            limine bios-install "$disk" || echo "Warning: limine bios-install failed on $disk." >&2
        fi

        echo "Limine installed to the MBR of $disk (BIOS/legacy), boot files at $ldir. GRUB files remain on disk, but its MBR boot code has been replaced by Limine."
    fi

    mkdir -p /etc/pacman.d/hooks
    cat > /etc/pacman.d/hooks/95-limine-sync.hook <<HOOK
[Trigger]
Operation = Install
Operation = Upgrade
Operation = Remove
Type = Package
Target = linux*
Target = booster
Target = limine
Target = amd-ucode
Target = intel-ucode

[Action]
Description = Syncing Limine boot files and config to the boot partition
When = PostTransaction
Exec = /usr/local/bin/limine-sync
HOOK
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
            local dinit_src="" dinit_dir
            for dinit_dir in /etc/dinit.d /usr/lib/dinit.d; do
                if [ -e "$dinit_dir/$service_name" ]; then
                    dinit_src="$dinit_dir/$service_name"
                    break
                fi
            done
            if [ -z "$dinit_src" ]; then
                echo "Warning: no dinit service named $service_name found in /etc/dinit.d or /usr/lib/dinit.d, not enabling it (is $service_name-dinit installed?)." >&2
                return 1
            fi
            mkdir -p /etc/dinit.d/boot.d
            ln -sf "$dinit_src" "/etc/dinit.d/boot.d/$service_name"
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

pacman -Sy --noconfirm --needed git base-devel
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

pacman -U --noconfirm "https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst" "https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst"
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
  if pacman -Syyu --noconfirm --needed --overwrite="*" --ignore=linux,linux-headers,nvidia-390xx-utils,lib32-nvidia-390xx-utils,modemmanager; then
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
  downgrade rust chkrootkit expect earlyoom \
  inotify-tools preload dialog tree parallel sof-firmware booster vulkan-tools mimalloc mold \
  protontricks-git poetry pyenv python-pip ccache yt-dlp-git \
  lib32-libdisplay-info realtime-privileges gallery-dl tesseract-data-eng \
  scx-scheds debtap fwupd chrony dnsmasq mesa lib32-mesa tk nix rsync limine

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
          ufw-s6 earlyoom-s6
        ;;
    openrc)
        careful_install \
          dnscrypt-proxy-openrc dnsmasq-openrc apparmor-openrc clamav-openrc \
          ufw-openrc earlyoom-openrc
        ;;
    runit)
        careful_install \
          dnscrypt-proxy-runit dnsmasq-runit apparmor-runit clamav-runit \
          ufw-runit earlyoom-runit
        ;;
    dinit)
        careful_install \
          dnscrypt-proxy-dinit dnsmasq-dinit apparmor-dinit clamav-dinit \
          ufw-dinit earlyoom-dinit networkmanager-dinit
        ;;
esac

# AMD-DESKTOP CHOICE
if [ "$choice" = "1" ]; then
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
  careful_install \
    linux-xanmod-edge-x64v3 linux-xanmod-edge-x64v3-headers protonup-git \
    nvidia-utils $(init_pkg nvidia-utils) nvidia-settings \
    fail2ban $(init_pkg fail2ban) cpupower $(init_pkg cpupower) nvidia-open-dkms
  # lib32 NVIDIA / Vulkan fallback
  careful_install lib32-nvidia-utils || careful_install lib32-vulkan-driver
fi

# NVIDIA-PROPRIETARY-DESKTOP CHOICE
if [ "$choice" = "6" ]; then
  careful_install \
    linux-xanmod-edge-x64v3 linux-xanmod-edge-x64v3-headers protonup-git \
    nvidia-utils $(init_pkg nvidia-utils) nvidia-settings \
    fail2ban $(init_pkg fail2ban) cpupower $(init_pkg cpupower) nvidia-dkms
  # lib32 NVIDIA / Vulkan fallback
  careful_install lib32-nvidia-utils || careful_install lib32-vulkan-driver
fi

### SWITCH INITRAMFS GENERATION FROM MKINITCPIO TO BOOSTER ###

# booster runs "fsck -y"; fsck.f2fs treats -y like -f and does a full forced check every boot, so f2fs is left out
BOOSTER_ROOTFS=$(findmnt -no FSTYPE /)
case "$BOOSTER_ROOTFS" in
    ext2|ext3|ext4)
        if command -v fsck &>/dev/null && command -v "fsck.$BOOSTER_ROOTFS" &>/dev/null && ! grep -q "^extra_files:" /etc/booster.yaml 2>/dev/null; then
            echo "extra_files: fsck,fsck.$BOOSTER_ROOTFS" >> /etc/booster.yaml
        fi
        ;;
esac

run_boot_params

shopt -s nullglob
KERNELS=0
MISSING_BOOSTER=()
for m in /usr/lib/modules/*/pkgbase; do
    pacman -Qqo "$m" &>/dev/null || continue
    read -r p < "$m"
    v="${m%/pkgbase}"; v="${v##*/}"
    KERNELS=$((KERNELS + 1))
    if install -Dm644 "${m%/pkgbase}/vmlinuz" "/boot/vmlinuz-$p" && (umask 0077; booster build --force --kernel-version "$v" "/boot/booster-$p.img.new") && booster_image_ok "/boot/booster-$p.img.new" "$v"; then
        mv -f "/boot/booster-$p.img.new" "/boot/booster-$p.img"
    else
        rm -f "/boot/booster-$p.img.new"
        MISSING_BOOSTER+=("$p")
    fi
done
shopt -u nullglob

if [ "$KERNELS" -gt 0 ] && [ "${#MISSING_BOOSTER[@]}" -eq 0 ]; then
    for img in /boot/booster-*.img; do
        base=$(basename "$img")
        ln -sf "$base" "/boot/${base/booster-/initramfs-}"
    done

    if pacman -Qi mkinitcpio &>/dev/null; then
        paru -Rdd --noconfirm mkinitcpio
    fi
else
    echo "Warning: booster build failed for kernel(s): ${MISSING_BOOSTER[*]:-none found in /usr/lib/modules}. Leaving mkinitcpio in place; Limine will leave these kernels out." >&2
fi

# IMPORT FLATPAK BETA REPO
flatpak remote-add flathub-beta https://flathub.org/beta-repo/flathub-beta.flatpakrepo

# INSTALL PROTON-GE
if pacman -Q protonup-git &>/dev/null; then
    su - "$USER" -c "protonup -d /home/$USER/.local/share/Steam/compatibilitytools.d/ && protonup -y"
fi

### ULU EXTERNAL TOOLS ###

install_ulu_external_tools

### ULU INSTALL ###

# AMD/INTEL SELECTION
if [ "$choice" = "1" ] || [ "$choice" = "3" ]; then
  install_ulu_package ulu-root-main
  install_ulu_package ulu-root-programs
  add_service fail2ban
  add_service cpupower
fi

# LAPTOP SELECTION
if [ "$choice" = "2" ] || [ "$choice" = "4" ]; then
  install_ulu_package ulu-root-main
  install_ulu_package ulu-root-programs
  install_ulu_package ulu-root-laptop
  add_service tlp
fi

# NVIDIA SELECTION
if [ "$choice" = "5" ] || [ "$choice" = "6" ]; then
  install_ulu_package ulu-root-main
  install_ulu_package ulu-root-programs
  install_ulu_package ulu-nvidia-patch
  add_service fail2ban
  add_service cpupower
fi

# Stop here unless every file above was replaced and verified
check_ulu_install

# fail2ban reads the journal on systemd; other inits use the log files set in paths-overrides.local
[ "$INIT_SYSTEM" = "systemd" ] && rm -f /etc/fail2ban/paths-overrides.local

### LAST COMMANDS ###

# ADD SERVICES
add_service apparmor
add_service dnscrypt-proxy
add_service dnsmasq
add_service ufw
add_service earlyoom
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
install_limine

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

# dinit
if [ "$INIT_SYSTEM" = "dinit" ] && [ -f /etc/rc.local ]; then
    if ! head -1 /etc/rc.local | grep -q "^#!"; then
        sed -i "1i #!/bin/bash" /etc/rc.local
    fi
    chmod 755 /etc/rc.local
fi

# DINIT SERVICE CHECK (reports syntax errors, invalid values, missing services and dependency cycles)
if [ "$INIT_SYSTEM" = "dinit" ] && command -v dinitcheck &>/dev/null; then
    echo -e "\e[1mChecking dinit service configuration...\e[0m"
    if ! dinitcheck; then
        echo "Warning: dinitcheck reported problems with the dinit services (see above)." >&2
    fi
fi

# RESET PERMISSIONS
reset-permissions

# HARDENING SCRIPT
hardening-script

# EXIT
cd /
rm -rf /home/ulu-files/
echo -e "\e[1mULU has been successfully installed\e[0m"
reboot

elif command -v xbps-install &>/dev/null; then



######################
# VOID LINUX SECTION #
######################

### SERVICE MANAGEMENT FUNCTIONS ###

add_service() {
    local service_name="$1"
    if [ ! -d "/etc/sv/$service_name" ]; then
        echo "Warning: /etc/sv/$service_name does not exist, not enabling $service_name." >&2
        return 1
    fi
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

### LIMINE CONFIGURATION ###

install_limine() {
    local label

    # limine-sync reads the kernel cmdline and timeout from /etc/default/grub on every run
    if ! grep -q "^GRUB_CMDLINE_LINUX" /etc/default/grub 2>/dev/null; then
        echo "Warning: no GRUB_CMDLINE_LINUX in /etc/default/grub, skipping Limine setup." >&2
        return 1
    fi
    label="Limine"

    local bootsrc
    bootsrc=$(findmnt -no SOURCE --target /boot 2>/dev/null); bootsrc=${bootsrc%%\[*}
    if lsblk -nrso TYPE "$bootsrc" 2>/dev/null | grep -qx crypt; then
        echo "Warning: /boot is encrypted, and Limine would copy the kernel and initramfs to the unencrypted boot partition. Keeping GRUB (cryptodisk) as the bootloader." >&2
        return 1
    fi
    local rootuuid cmdline ldir
    rootuuid=$(findmnt -no UUID --target /)
    cmdline="root=UUID=$rootuuid rw"

    if [ -d /sys/firmware/efi ]; then
        # ================= UEFI: register an NVRAM boot entry =================
        careful_install efibootmgr

        local esp espdev espfstype
        esp=$(findmnt -no TARGET --target /boot/efi 2>/dev/null || findmnt -no TARGET --target /efi 2>/dev/null || findmnt -no TARGET --target /boot)
        espdev=$(findmnt -no SOURCE --target "$esp")
        espfstype=$(blkid -p -o value -s TYPE "$espdev" 2>/dev/null)
        if [ "$espfstype" != "vfat" ]; then
            echo "Warning: the ESP at $esp ($espdev) is $espfstype, not vfat/FAT32 as UEFI firmware requires. Skipping Limine and keeping GRUB, which already boots this system fine, as the sole bootloader." >&2
            return 1
        fi
        ldir="$esp/EFI/limine"

        cat > /usr/local/bin/limine-sync <<SYNC
#!/bin/bash
set -euo pipefail
shopt -s nullglob
GRUB_TIMEOUT=3 GRUB_CMDLINE_LINUX_DEFAULT="" GRUB_CMDLINE_LINUX=""
[ -r /etc/default/grub ] && . /etc/default/grub
case " \$GRUB_CMDLINE_LINUX " in
    *" rd.luks.key="*) echo "limine-sync: FAIL: the initramfs carries a LUKS keyfile; not copying it to the unencrypted boot partition" >&2; exit 1 ;;
esac
mkdir -p "$ldir"
install -Dm755 /usr/share/limine/BOOTX64.EFI "$ldir/BOOTX64.EFI"
install -Dm755 /usr/share/limine/BOOTX64.EFI "$esp/EFI/BOOT/BOOTX64.EFI"
booster_for() {
    local y
    y=\$(booster cat "\$1" etc/booster.init.yaml 2>/dev/null) || return 1
    grep -qxF "kernel: \$2" < <(printf "%s\n" "\$y" | tr -d "\047\"")
}
build_booster() {
    local v="\$1" out="\$2" avail m keep="" dropped="" cfg
    if (umask 0077; booster build --force --kernel-version "\$v" "\$out.new") >&2; then mv -f "\$out.new" "\$out"; return 0; fi
    rm -f "\$out.new"
    avail=\$(sed -e "s/:.*//" "/usr/lib/modules/\$v/modules.dep" "/usr/lib/modules/\$v/modules.builtin" 2>/dev/null | sed -e "s|.*/||" -e "s/\.ko.*//" | tr - _) || true
    for m in \$(sed -n "s/^modules_force_load://p" /etc/booster.yaml | tr "," " "); do
        if grep -qxF "\${m//-/_}" <<< "\$avail"; then keep+="\$m,"; else dropped+=" \$m"; fi
    done
    [ -n "\$dropped" ] || return 1
    cfg=\$(mktemp)
    sed "/^modules_force_load:/d" /etc/booster.yaml > "\$cfg"
    if [ -n "\$keep" ]; then echo "modules_force_load: \${keep%,}" >> "\$cfg"; fi
    echo "limine-sync: kernel \$v lacks force-loaded module(s):\$dropped; building its booster image without them" >&2
    if (umask 0077; booster build --force --config "\$cfg" --kernel-version "\$v" "\$out.new") >&2; then mv -f "\$out.new" "\$out"; rm -f "\$cfg"; return 0; fi
    rm -f "\$out.new" "\$cfg"
    return 1
}
stage() {
    cmp -s "\$1" "$ldir/\${1##*/}" || cp -f "\$1" "$ldir/"
    keep+="\${1##*/} "
}
n=0
skipped=""
keep=" "
{
    echo "timeout: \${GRUB_TIMEOUT:-3}"
    while read -r v; do
        [ -n "\$v" ] || continue
        k="/boot/vmlinuz-\$v"; i="/boot/initramfs-\$v.img"; label="\$v"
        [ -f "\$k" ] || continue
        if ! booster_for "\$i" "\$v" && [ -d "/usr/lib/modules/\$v" ]; then
            build_booster "\$v" "\$i" || true
        fi
        if ! booster_for "\$i" "\$v"; then
            skipped+=" \$label"
            continue
        fi
        stage "\$k"
        stage "\$i"
        n=\$((n + 1))
        printf "\n/Linux (%s)\n    protocol: linux\n    path: boot():/EFI/limine/%s\n    cmdline: %s\n" "\$label" "\${k##*/}" "$cmdline \$GRUB_CMDLINE_LINUX_DEFAULT \$GRUB_CMDLINE_LINUX"
        for u in amd-ucode.img intel-ucode.img; do
            if [ -f "/boot/\$u" ]; then
                stage "/boot/\$u"
                echo "    module_path: boot():/EFI/limine/\$u"
            fi
        done
        echo "    module_path: boot():/EFI/limine/\${i##*/}"
    done < <(for f in /boot/vmlinuz-*; do echo "\${f##*/vmlinuz-}"; done | sort -rV)
} > "$ldir/limine.conf.new"
if [ "\$n" -eq 0 ]; then
    rm -f "$ldir/limine.conf.new"
    echo "limine-sync: FAIL: no kernel has a booster initramfs built for it; $ldir/limine.conf left unchanged" >&2
    exit 1
fi
mv -f "$ldir/limine.conf.new" "$ldir/limine.conf"
for f in "$ldir"/vmlinuz-* "$ldir"/initramfs-*.img "$ldir"/*-ucode.img; do
    case "\$keep" in *" \${f##*/} "*) ;; *) rm -f "\$f" ;; esac
done
if [ -n "\$skipped" ]; then
    echo "limine-sync: FAIL: no booster initramfs for:\$skipped (left out of $ldir/limine.conf; \$n entries written)" >&2
else
    echo "limine-sync: PASS: \$n Limine entries, each with a booster initramfs built for its kernel"
fi
SYNC
        chmod +x /usr/local/bin/limine-sync
        if ! /usr/local/bin/limine-sync; then
            echo "Warning: limine-sync failed while staging Limine files to $ldir. Skipping NVRAM entry; GRUB remains the sole bootloader." >&2
            return 1
        fi

        if [ ! -f "$ldir/BOOTX64.EFI" ] || [ ! -f "$esp/EFI/BOOT/BOOTX64.EFI" ] || [ ! -s "$ldir/limine.conf" ]; then
            echo "Warning: limine-sync ran but BOOTX64.EFI and/or limine.conf are missing under $esp. Skipping NVRAM entry; GRUB remains the sole bootloader." >&2
            return 1
        fi

        local dev disk part
        dev="$espdev"
        disk="/dev/$(lsblk -no PKNAME "$dev")"
        part=$(cat "/sys/class/block/$(basename "$dev")/partition")

        if ! efibootmgr | grep -q "$label"; then
            if ! efibootmgr --create --disk "$disk" --part "$part" --label "$label" --loader "\EFI\limine\BOOTX64.EFI" --unicode >/dev/null; then
                echo "Warning: efibootmgr --create failed for label \"$label\" on $disk part $part. Boot files are staged at $ldir but no NVRAM entry exists; GRUB remains the sole bootloader." >&2
                return 1
            fi
        fi

        local bootnum current_order new_order
        bootnum=$(efibootmgr | grep -F "$label" | grep -oE "^Boot[0-9A-Fa-f]{4}" | sed "s/^Boot//" | head -n1)
        if [ -n "$bootnum" ]; then
            current_order=$(efibootmgr | grep "^BootOrder:" | cut -d" " -f2)
            new_order="$bootnum,$(printf "%s" "$current_order" | tr "," "\n" | grep -vx "$bootnum" | paste -sd, -)"
            efibootmgr -o "${new_order%,}" >/dev/null || echo "Warning: could not set BootOrder to pin \"$label\" first; check efibootmgr output." >&2
        else
            echo "Warning: could not find the \"$label\" boot entry to pin it first; check efibootmgr output." >&2
        fi

        # ---- Verify the UEFI installation actually took ----
        if efibootmgr | grep -q "$label" && [ -f "$ldir/BOOTX64.EFI" ] && [ -f "$esp/EFI/BOOT/BOOTX64.EFI" ]; then
            echo "Verified: Limine installed at $ldir (UEFI, label: $label), NVRAM entry present. GRUB remains fully intact as a fallback boot entry."
        else
            echo "Warning: post-install verification failed for UEFI Limine setup (label \"$label\"). Check efibootmgr output and files under $esp." >&2
        fi
    else
        # ================= BIOS/legacy: write Limine into the MBR =================
        local bootmnt bootdev disk name typ fstype fatpart="" fatmnt
        bootmnt=$(findmnt -no TARGET --target /boot 2>/dev/null); [ -n "$bootmnt" ] || bootmnt=/
        bootdev=$(findmnt -no SOURCE --target "$bootmnt"); bootdev=${bootdev%%\[*}
        disk=""
        while read -r name typ; do
            if [ "$typ" = disk ]; then
                disk="/dev/$name"
                break
            fi
        done < <(lsblk -nrso NAME,TYPE "$bootdev")

        while read -r name typ; do
            [ "$typ" = "part" ] || continue
            fstype=$(blkid -p -o value -s TYPE "/dev/$name" 2>/dev/null)
            if [ "$fstype" = "vfat" ]; then
                fatpart="$name"
                break
            fi
        done < <(lsblk -rno NAME,TYPE "$disk")

        if [ -z "$fatpart" ]; then
            echo "Warning: no FAT partition found on $disk. The Limine BIOS boot stage only reads FAT12/16/32 (or ISO9660), and the boot filesystem on this system does not qualify. Skipping Limine and keeping GRUB, which already boots this filesystem fine, as the sole bootloader." >&2
            return 1
        fi

        fatmnt=$(findmnt -no TARGET "/dev/$fatpart" 2>/dev/null)
        if [ -z "$fatmnt" ]; then
            fatmnt=/boot/limine-boot
            mkdir -p "$fatmnt"
            mount "/dev/$fatpart" "$fatmnt"
            if ! grep -q "[[:space:]]${fatmnt}[[:space:]]" /etc/fstab 2>/dev/null; then
                local fatuuid
                fatuuid=$(blkid -p -o value -s UUID "/dev/$fatpart" 2>/dev/null)
                [ -n "$fatuuid" ] && echo "UUID=$fatuuid $fatmnt vfat defaults,noatime 0 2" >> /etc/fstab
            fi
        fi
        ldir="$fatmnt/limine"

        cat > /usr/local/bin/limine-sync <<SYNC
#!/bin/bash
set -euo pipefail
shopt -s nullglob
GRUB_TIMEOUT=3 GRUB_CMDLINE_LINUX_DEFAULT="" GRUB_CMDLINE_LINUX=""
[ -r /etc/default/grub ] && . /etc/default/grub
case " \$GRUB_CMDLINE_LINUX " in
    *" rd.luks.key="*) echo "limine-sync: FAIL: the initramfs carries a LUKS keyfile; not copying it to the unencrypted boot partition" >&2; exit 1 ;;
esac
mkdir -p "$ldir"
install -Dm644 /usr/share/limine/limine-bios.sys "$ldir/limine-bios.sys"
booster_for() {
    local y
    y=\$(booster cat "\$1" etc/booster.init.yaml 2>/dev/null) || return 1
    grep -qxF "kernel: \$2" < <(printf "%s\n" "\$y" | tr -d "\047\"")
}
build_booster() {
    local v="\$1" out="\$2" avail m keep="" dropped="" cfg
    if (umask 0077; booster build --force --kernel-version "\$v" "\$out.new") >&2; then mv -f "\$out.new" "\$out"; return 0; fi
    rm -f "\$out.new"
    avail=\$(sed -e "s/:.*//" "/usr/lib/modules/\$v/modules.dep" "/usr/lib/modules/\$v/modules.builtin" 2>/dev/null | sed -e "s|.*/||" -e "s/\.ko.*//" | tr - _) || true
    for m in \$(sed -n "s/^modules_force_load://p" /etc/booster.yaml | tr "," " "); do
        if grep -qxF "\${m//-/_}" <<< "\$avail"; then keep+="\$m,"; else dropped+=" \$m"; fi
    done
    [ -n "\$dropped" ] || return 1
    cfg=\$(mktemp)
    sed "/^modules_force_load:/d" /etc/booster.yaml > "\$cfg"
    if [ -n "\$keep" ]; then echo "modules_force_load: \${keep%,}" >> "\$cfg"; fi
    echo "limine-sync: kernel \$v lacks force-loaded module(s):\$dropped; building its booster image without them" >&2
    if (umask 0077; booster build --force --config "\$cfg" --kernel-version "\$v" "\$out.new") >&2; then mv -f "\$out.new" "\$out"; rm -f "\$cfg"; return 0; fi
    rm -f "\$out.new" "\$cfg"
    return 1
}
stage() {
    cmp -s "\$1" "$ldir/\${1##*/}" || cp -f "\$1" "$ldir/"
    keep+="\${1##*/} "
}
n=0
skipped=""
keep=" "
{
    echo "timeout: \${GRUB_TIMEOUT:-3}"
    while read -r v; do
        [ -n "\$v" ] || continue
        k="/boot/vmlinuz-\$v"; i="/boot/initramfs-\$v.img"; label="\$v"
        [ -f "\$k" ] || continue
        if ! booster_for "\$i" "\$v" && [ -d "/usr/lib/modules/\$v" ]; then
            build_booster "\$v" "\$i" || true
        fi
        if ! booster_for "\$i" "\$v"; then
            skipped+=" \$label"
            continue
        fi
        stage "\$k"
        stage "\$i"
        n=\$((n + 1))
        printf "\n/Linux (%s)\n    protocol: linux\n    path: boot():/limine/%s\n    cmdline: %s\n" "\$label" "\${k##*/}" "$cmdline \$GRUB_CMDLINE_LINUX_DEFAULT \$GRUB_CMDLINE_LINUX"
        for u in amd-ucode.img intel-ucode.img; do
            if [ -f "/boot/\$u" ]; then
                stage "/boot/\$u"
                echo "    module_path: boot():/limine/\$u"
            fi
        done
        echo "    module_path: boot():/limine/\${i##*/}"
    done < <(for f in /boot/vmlinuz-*; do echo "\${f##*/vmlinuz-}"; done | sort -rV)
} > "$ldir/limine.conf.new"
if [ "\$n" -eq 0 ]; then
    rm -f "$ldir/limine.conf.new"
    echo "limine-sync: FAIL: no kernel has a booster initramfs built for it; $ldir/limine.conf left unchanged" >&2
    exit 1
fi
mv -f "$ldir/limine.conf.new" "$ldir/limine.conf"
for f in "$ldir"/vmlinuz-* "$ldir"/initramfs-*.img "$ldir"/*-ucode.img; do
    case "\$keep" in *" \${f##*/} "*) ;; *) rm -f "\$f" ;; esac
done
if [ -n "\$skipped" ]; then
    echo "limine-sync: FAIL: no booster initramfs for:\$skipped (left out of $ldir/limine.conf; \$n entries written)" >&2
else
    echo "limine-sync: PASS: \$n Limine entries, each with a booster initramfs built for its kernel"
fi
SYNC
        chmod +x /usr/local/bin/limine-sync
        if ! /usr/local/bin/limine-sync; then
            echo "Warning: limine-sync found no kernel with a booster initramfs. Skipping limine bios-install; GRUB stays in the MBR." >&2
            return 1
        fi

        local pttype biospart="" ptype biospartnum
        pttype=$(blkid -p -o value -s PTTYPE "$disk" 2>/dev/null)
        if [ "$pttype" = "gpt" ]; then
            while read -r name typ; do
                [ "$typ" = "part" ] || continue
                ptype=$(blkid -p -o value -s PART_ENTRY_TYPE "/dev/$name" 2>/dev/null | tr "[:upper:]" "[:lower:]")
                if [ "$ptype" = "21686148-6449-6e6f-744e-656564454649" ]; then
                    biospart="$name"
                    break
                fi
            done < <(lsblk -rno NAME,TYPE "$disk")
        fi

        if [ -n "$biospart" ]; then
            biospartnum=$(blkid -p -o value -s PART_ENTRY_NUMBER "/dev/$biospart" 2>/dev/null)
            limine bios-install "$disk" "$biospartnum" || echo "Warning: limine bios-install failed on $disk (bios_grub partition $biospartnum)." >&2
        elif [ "$pttype" = "gpt" ]; then
            limine bios-install "$disk" || echo "Warning: limine bios-install failed on $disk. This GPT disk has no spare bios_grub-type partition (GUID 21686148-6449-6E6F-744E-656564454649, 32KiB+) and embedding into GPT structures did not succeed either; create one and re-run." >&2
        else
            limine bios-install "$disk" || echo "Warning: limine bios-install failed on $disk." >&2
        fi

        echo "Limine installed to the MBR of $disk (BIOS/legacy), boot files at $ldir. GRUB files remain on disk, but its MBR boot code has been replaced by Limine."
    fi

    mkdir -p /etc/kernel.d/post-install /etc/kernel.d/post-remove
    cat > /etc/kernel.d/post-install/60-limine-sync <<HOOK
#!/bin/sh
exec /usr/local/bin/limine-sync
HOOK
    cat > /etc/kernel.d/post-remove/60-limine-sync <<HOOK
#!/bin/sh
exec /usr/local/bin/limine-sync
HOOK
    chmod +x /etc/kernel.d/post-install/60-limine-sync /etc/kernel.d/post-remove/60-limine-sync
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

xbps-install -Syu git xbps
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
  rust chkrootkit alsa-utils expect \
  inotify-tools preload dialog tree parallel sof-firmware booster Vulkan-Tools mimalloc mold \
  protontricks python3-pip ccache yt-dlp \
  libdisplay-info-32bit gallery-dl tesseract-ocr tesseract-ocr-eng \
  fwupd chrony dnsmasq mesa mesa-32bit tk scx libgamemode-32bit nix rsync limine

# Headers for the currently running/installed kernel (needed by DKMS drivers like NVIDIA).
KVER=$(uname -r | cut -d. -f1-2)
if [ -n "$KVER" ]; then
  careful_install "linux${KVER}-headers"
fi

# AMD-DESKTOP CHOICE
if [ "$choice" = "1" ]; then
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
  careful_install \
    nvidia nvidia-libs-32bit \
    fail2ban cpupower
fi

# NVIDIA-PROPRIETARY-DESKTOP CHOICE
if [ "$choice" = "6" ]; then
  careful_install \
    nvidia580 nvidia580-libs-32bit \
    fail2ban cpupower
fi

### KEEP GPU DRIVERS OUT OF BOOSTER ###

# runit stage 1 (02-udev.sh) loads the GPU driver and runs udevadm settle before any service starts;
# force-loading GPU drivers here puts them ahead of the storage drivers in the kernel module-load queue
sed -i "/^modules_force_load:/d" /etc/booster.yaml

run_boot_params

### SWITCH INITRAMFS GENERATION FROM DRACUT TO BOOSTER ###

# The Void booster package ships no regenerate_images; its kernel hook writes /boot/initramfs-<version>.img
xbps-alternatives -s booster || echo "Warning: xbps-alternatives -s booster failed; dracut kernel hooks may remain active for future kernel updates." >&2

shopt -s nullglob
VMLINUZ_FILES=(/boot/vmlinuz-*)
MISSING_BOOSTER=()
for k in "${VMLINUZ_FILES[@]}"; do
    kver="${k##*/vmlinuz-}"
    if [ -d "/usr/lib/modules/$kver" ] && (umask 0077; booster build --force --kernel-version "$kver" "/boot/initramfs-$kver.img.new") && booster_image_ok "/boot/initramfs-$kver.img.new" "$kver"; then
        mv -f "/boot/initramfs-$kver.img.new" "/boot/initramfs-$kver.img"
    else
        rm -f "/boot/initramfs-$kver.img.new"
        MISSING_BOOSTER+=("$kver")
    fi
done
shopt -u nullglob

# linux-base depends on dracut and booster provides no substitute, so dracut must be ignored before xbps will remove it
if [ "${#VMLINUZ_FILES[@]}" -gt 0 ] && [ "${#MISSING_BOOSTER[@]}" -eq 0 ]; then
    mkdir -p /etc/xbps.d
    echo "ignorepkg=dracut" > /etc/xbps.d/ignore-dracut.conf
    if xbps-query dracut &>/dev/null; then
        xbps-remove -y dracut || echo "Warning: xbps-remove dracut failed; booster stays the active initramfs alternative regardless." >&2
    fi
else
    echo "Warning: booster build failed for kernel(s): ${MISSING_BOOSTER[*]:-none found in /boot}. Leaving dracut installed; Limine will leave these kernels out and GRUB still has their dracut images." >&2
fi

# IMPORT FLATPAK BETA REPO
flatpak remote-add flathub-beta https://flathub.org/beta-repo/flathub-beta.flatpakrepo

# INSTALL PROTON-GE
if xbps-query protonup-ng &>/dev/null; then
    su - "$USER" -c "protonup -d /home/$USER/.local/share/Steam/compatibilitytools.d/ && protonup -y"
fi

### ULU EXTERNAL TOOLS ###

install_ulu_external_tools

### ULU INSTALL ###

# AMD/INTEL SELECTION
if [ "$choice" = "1" ] || [ "$choice" = "3" ]; then
  install_ulu_package ulu-root-main
  install_ulu_package ulu-root-programs
  add_service fail2ban
fi

# LAPTOP SELECTION
if [ "$choice" = "2" ] || [ "$choice" = "4" ]; then
  install_ulu_package ulu-root-main
  install_ulu_package ulu-root-programs
  install_ulu_package ulu-root-laptop
  add_service tlp
fi

# NVIDIA SELECTION
if [ "$choice" = "5" ] || [ "$choice" = "6" ]; then
  install_ulu_package ulu-root-main
  install_ulu_package ulu-root-programs
  install_ulu_package ulu-nvidia-patch
  add_service fail2ban
fi

# Stop here unless every file above was replaced and verified
check_ulu_install

### LAST COMMANDS ###

# ADD SERVICES
add_service apparmor
add_service dnscrypt-proxy
add_service dnsmasq
add_service ufw
add_service earlyoom

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
install_limine

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
echo -e "\e[1mULU has been successfully installed\e[0m"
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

### INSTALL PACKAGES ONE BY ONE WITH RETRIES ###

careful_install() {
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
apt-get install -y --no-install-recommends ca-certificates curl gnupg wget git software-properties-common apt-transport-https

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
    careful_install network-manager

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
  unrar flatpak gamemode libgamemode0:i386 dnscrypt-proxy apparmor apparmor-utils \
  clamav clamav-daemon gufw macchanger wine winetricks steam-installer lynis rkhunter doas \
  rustc cargo chkrootkit expect earlyoom \
  inotify-tools preload dialog tree parallel firmware-sof-signed vulkan-tools libmimalloc2.0 mold \
  python3-pip ccache yt-dlp \
  gallery-dl tesseract-ocr-eng \
  fwupd chrony dnsmasq mesa-utils libgl1-mesa-dri:i386 tk

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
    careful_install "$kernel_pkg" || careful_install "linux-xanmod-x64v3" || careful_install linux-xanmod
}

# AMD-DESKTOP CHOICE
if [ "$choice" = "1" ]; then
    install_xanmod_kernel edge
    careful_install mesa-vulkan-drivers mesa-vulkan-drivers:i386 vainfo fail2ban linux-tools-common linux-tools-generic
fi

# AMD-LAPTOP CHOICE
if [ "$choice" = "2" ]; then
    install_xanmod_kernel ""
    careful_install mesa-vulkan-drivers mesa-vulkan-drivers:i386 vainfo tlp tlp-rdw blueman bluez brightnessctl
fi

# INTEL-DESKTOP CHOICE
if [ "$choice" = "3" ]; then
    install_xanmod_kernel edge
    careful_install mesa-vulkan-drivers mesa-vulkan-drivers:i386 vainfo fail2ban linux-tools-common linux-tools-generic
fi

# INTEL-LAPTOP CHOICE
if [ "$choice" = "4" ]; then
    install_xanmod_kernel ""
    careful_install mesa-vulkan-drivers mesa-vulkan-drivers:i386 vainfo tlp tlp-rdw blueman bluez brightnessctl
fi

# NVIDIA-OPENSOURCE-DESKTOP CHOICE
if [ "$choice" = "5" ]; then
    install_xanmod_kernel edge
    apt-get install -y --no-install-recommends ubuntu-drivers-common 2>/dev/null || true
    RECOMMENDED_DRIVER=$(ubuntu-drivers devices 2>/dev/null | awk "/recommended/{print \$3}" | head -n1)
    if [ -n "$RECOMMENDED_DRIVER" ]; then
        careful_install "${RECOMMENDED_DRIVER}-open" || careful_install "$RECOMMENDED_DRIVER"
    else
        ubuntu-drivers autoinstall || true
    fi
    careful_install vainfo fail2ban linux-tools-common linux-tools-generic
fi

# NVIDIA-PROPRIETARY-DESKTOP CHOICE
if [ "$choice" = "6" ]; then
    install_xanmod_kernel edge
    apt-get install -y --no-install-recommends ubuntu-drivers-common 2>/dev/null || true
    RECOMMENDED_DRIVER=$(ubuntu-drivers devices 2>/dev/null | awk "/recommended/{print \$3}" | head -n1)
    if [ -n "$RECOMMENDED_DRIVER" ]; then
        careful_install "$RECOMMENDED_DRIVER"
    else
        ubuntu-drivers autoinstall || true
    fi
    careful_install vainfo fail2ban linux-tools-common linux-tools-generic
fi

### IMPORT FLATHUB + FLATPAK BETA REPOS ###

flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak remote-add --if-not-exists flathub-beta https://flathub.org/beta-repo/flathub-beta.flatpakrepo

### ULU EXTERNAL TOOLS ###

install_ulu_external_tools

### ULU INSTALL ###

# AMD/INTEL SELECTION
if [ "$choice" = "1" ] || [ "$choice" = "3" ]; then
    install_ulu_package ulu-root-main
    install_ulu_package ulu-root-programs
    add_service fail2ban
    add_service cpupower
fi

# LAPTOP SELECTION
if [ "$choice" = "2" ] || [ "$choice" = "4" ]; then
    install_ulu_package ulu-root-main
    install_ulu_package ulu-root-programs
    install_ulu_package ulu-root-laptop
    add_service tlp
fi

# NVIDIA SELECTION
if [ "$choice" = "5" ] || [ "$choice" = "6" ]; then
    install_ulu_package ulu-root-main
    install_ulu_package ulu-root-programs
    install_ulu_package ulu-nvidia-patch
    add_service fail2ban
    add_service cpupower
fi

# Stop here unless every file above was replaced and verified
check_ulu_install

# fail2ban reads the journal on systemd; paths-overrides.local is only for other inits
rm -f /etc/fail2ban/paths-overrides.local

### ADAPT ULU NETWORKMANAGER/DNSMASQ/DNSCRYPT-PROXY CONFIGS FOR APT ###

echo -e "\e[1mAdapting dnscrypt-proxy/dnsmasq/NetworkManager configs for apt...\e[0m"

if [ -L /etc/resolv.conf ]; then
    rm -f /etc/resolv.conf
    install_ulu_package ulu-root-main etc/resolv.conf
    check_ulu_install
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
if command -v ufw &>/dev/null; then
    add_service ufw
fi

run_boot_params
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
echo -e "\e[1mULU has been successfully installed\e[0m"
reboot

fi
'
