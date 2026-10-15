<p align="center">
	<img src="https://i.postimg.cc/90gfzGTT/tux-glasses.png" width="25%" />
</p>
<br>

<p align="center">
	<img src="https://i.postimg.cc/fbvDJcnG/740019dcf9a94a804d725079cedf0e2f250ea164da39a3ee5e6b4b0d3255bfef95601890afd80709da39a3ee5e6b4b0d3255.png" width="65%" />
</p>

## Summary / TLDR
ULU is a post-installation script and configuration set for Arch, Void, and Debian-based Linux distributions. It configures existing installations for gaming, low-latency workloads and improved security by installing packages and applying configurations. Utility commands are included also which help manage the system.

Originally I was inspired by Luke Smith's [LARBS](https://github.com/LukeSmithxyz/LARBS), which is why ULU's installer is script-based. If you want to see what changes I've made, the files ULU installs are in [files/ulu-packages](https://github.com/Michael-Sebero/ULU/tree/main/files/ulu-packages).

## **Core Components**

### **High Performance Kernel & Schedulers**
* [XanMod](https://xanmod.org/) - Custom Linux kernel optimized for speed, responsiveness and desktop performance
* [SCX-AURA](https://github.com/Michael-Sebero/SCX-AURA) - Laptop CPU scheduler based on [scx_bpfland](https://github.com/sched-ext/scx/tree/main/scheds/rust/scx_bpfland)
* [SCX-IMPERATOR](https://github.com/Michael-Sebero/SCX-IMPERATOR) - Gaming CPU scheduler based on [scx_cake](https://github.com/RitzDaCat/scx_cake) and [scx_lavd](https://github.com/sched-ext/scx/tree/main/scheds/rust/scx_lavd)

### **Security Software**
* [AppArmor](https://en.wikipedia.org/wiki/AppArmor) - Mandatory access control framework for process-level security
* [Chkrootkit](https://en.wikipedia.org/wiki/Chkrootkit) - Rootkit detection tool that scans for common signs of system compromise
* [ClamAV](https://github.com/Cisco-Talos/clamav) - Antivirus engine for detecting malware and trojans
* [DNSCrypt Proxy](https://github.com/DNSCrypt/dnscrypt-proxy) - Encrypted DNS client, set up for DNS-over-HTTPS to [LibreDNS](https://libredns.gr/)
* [DNSMasq](https://thekelleys.org.uk/dnsmasq/doc.html) - Local DNS cache that forwards queries to DNSCrypt Proxy
* [Fail2Ban](https://github.com/fail2ban/fail2ban) - Bans IP addresses after repeated failed SSH logins
* [Linux Hardening Script](https://github.com/Michael-Sebero/Linux-Hardening-Script) - Automated system security and configuration hardening script
* [Lynis](https://github.com/CISOfy/lynis) - Security auditing tool
* [Rkhunter](https://en.wikipedia.org/wiki/Rkhunter) - Rootkit, backdoor and local exploit scanner
* [UFW](https://en.wikipedia.org/wiki/Uncomplicated_Firewall) - Firewall front end for iptables

### **Additional Features**
* Includes a comprehensive [manual](https://raw.githubusercontent.com/Michael-Sebero/ULU/refs/heads/main/files/ulu-manual/Manual)
* Machine ID randomization: a new machine ID at every boot
* MAC address randomization: a new MAC address for every network connection at every boot
* [ALHP](https://wiki.archlinux.org/title/Unofficial_user_repositories#ALHP), [Chaotic AUR](https://github.com/chaotic-aur/packages) (for Arch-based systems) and [Flatpak](https://flatpak.org/) repositories
* [Proton GE](https://github.com/GloriousEggroll/proton-ge-custom) for Steam, installed with protonup
* [Booster](https://github.com/anatol/booster) - Fast initramfs generator that replaces mkinitcpio and dracut
* Battery life optimizations for laptops via [TLP](https://github.com/linrunner/TLP)
* [Mimalloc](https://github.com/microsoft/mimalloc) - High-performance memory allocator
* [Ephemeral Overlay](https://github.com/Michael-Sebero/Ephemeral-Overlay) - Frequently written directories are overlaid in OverlayFS/TMPFS to reduce disk I/O
* [Real-time](https://gitlab.archlinux.org/archlinux/packaging/packages/realtime-privileges) scheduling privileges for low-latency audio
* A [Lynis](https://github.com/CISOfy/lynis) system hardening rating of **78** (on the latest Lynis version)
* [GameMode](https://github.com/FeralInteractive/gamemode) - Performance on demand utility for games
* [NTSYNC](https://docs.kernel.org/userspace-api/ntsync.html) - Kernel driver for Windows NT synchronization primitives used by Wine/Proton, loaded at boot
* [SCX](https://github.com/sched-ext/scx) - Dynamic kernel scheduler framework
* [Package Dictionary](https://github.com/Michael-Sebero/Package-Dictionary) - Package search across pacman, the AUR, xbps, apt and Flatpak
* [Earlyoom](https://github.com/rfjakob/earlyoom) - Kills highest usage processes when RAM drops below 15% and free swap below 5%
* [Nix](https://nixos.org/) - Universal package manager
* [Limine](https://github.com/limine-bootloader/limine) - Fast boot loader, set as the default boot loader on Arch-based and Void systems

<div align="center">

## Feature Coverage

| Feature | Arch-based | Void Linux | Debian-based |
|:--|:---:|:---:|:---:|
| **SCX** | ✅ | ✅ | ✅ |
| **AppArmor** | ✅ | ✅ | ✅ |
| **Chkrootkit** | ✅ | ✅ | ✅ |
| **ClamAV** | ✅ | ✅ | ✅ |
| **DNSCrypt** | ✅ | ✅ | ✅ |
| **DNSMasq** | ✅ | ✅ | ✅ |
| **Fail2Ban** | ✅ | ✅ | ✅ |
| **Linux Hardening Script** | ✅ | ✅ | ✅ |
| **Lynis** | ✅ | ✅ | ✅ |
| **UFW** | ✅ | ✅ | ✅ |
| **x86-64-v3 Kernel** | ✅ | ❌ | ✅ |
| **x86-64-v3/v4 Repositories** | ✅ | ❌ | ❌ |
| **Booster** | ✅ | ✅ | ❌ |
| **Limine** | ✅ | ✅ | ❌ |
| **Machine ID Randomization** | ✅ | ✅ | ✅ |
| **MAC Address Randomization** | ✅ | ✅ | ✅ |
| **Flatpak** | ✅ | ✅ | ✅ |
| **Proton GE** | ✅ | ❌ | ❌ |
| **TLP** | ✅ | ✅ | ✅ |
| **Mimalloc** | ✅ | ✅ | ✅ |
| **Ephemeral Overlay** | ✅ | ✅ | ✅ |
| **Real-time Audio** | ✅ | ✅ | ✅ |
| **GameMode** | ✅ | ✅ | ✅ |
| **Package Dictionary** | ✅ | ✅ | ✅ |
| **Earlyoom** | ✅ | ✅ | ✅ |
| **Nix** | ✅ | ✅ | ✅ |

</div>

---

## How ULU Works

### Kernel & Security Hardening
ULU's `sysctl.conf` and kernel command line restrict kernel features that are common attack paths.

**Attack Surface Reduction:**
- ptrace is blocked for every process, root included, so debuggers such as gdb and strace don't work and the setting can't be lowered without a reboot. Laptops allow it for root only
- Unprivileged BPF is disabled and the BPF JIT compiler is hardened
- Core dumps are discarded to prevent information leakage
- Kernel pointers are hidden from all users
- SysRq is disabled and kexec is disabled to prevent the running kernel from being replaced
- Symlink, hardlink, FIFO and regular file protections are enabled
- AppArmor is enabled at boot

### Custom Kernel
The kernel which comes with the desktop configuration is a custom build of XanMod tailored for [x86-64-v3](https://en.wikipedia.org/wiki/X86-64#Microarchitecture_levels) CPU architecture. For laptops the default kernel is default but tailored for [x86-64-v3](https://en.wikipedia.org/wiki/X86-64#Microarchitecture_levels), XanMod uses more energy which is why it's not used for this configuration. Linux's default scheduler is replaced with a SCX-based scheduler for improved performance and responsiveness.

The x86-64-v3 kernels need a CPU with AVX2, BMI2, FMA and MOVBE. Intel Core and AMD Ryzen CPUs from 2017 onward have them; Pentium, Celeron and Atom CPUs of that era don't. The installer checks this before changing anything. At boot, a sched_ext scheduler takes over from the kernel's default scheduler for improved performance and responsiveness.

### Kernel Scheduler
The desktop scheduler is set to `IMPERATOR` and laptops use `AURA`. `IMPERATOR` is specialized for new processors (Zen 4-5 or CPUs with 3D V-Cache) and `AURA` for low latency and responsiveness with long battery life. The prebuilt `scx_imperator` binary needs AVX-512, so on CPUs without it, such as AMD Ryzen before Zen 4 (including Zen 3 X3D models) and most Intel desktop CPUs. If you want to change the scheduler, it can be modified in `rc.local` under the scheduler section.

### Memory Management
RAM usage has the highest priority over swapping. Keeping active data in memory reduces wear on the drive and increases system responsiveness. Swapping is still possible but only used when RAM is nearly full, first to ZRAM and then to any swap on disk. Proactive memory compaction is turned off and keeps directory and inode caches in memory longer. 16 HugePages (2 MB each) are reserved at boot and up to 3968 more are allocated on demand for programs that request them.

**ZRAM Integration:** `rc.local` sets up a compressed swap device in RAM, sized at 25% of total RAM and compressed with [LZ4](https://lz4.org/) on desktops and zstd on laptops. It is enabled with a higher priority than swap on disk and Zswap is turned off once it is active so pages aren't compressed twice.

### Ephemeral Overlay

**Tmpfs Mounts:**
- `/tmp` - 5 GB (stays on disk if an X server is already running when the overlay starts)
- `/var/tmp` - 1 GB
- `/var/cache` - 2 GB
- `/home/$USER/.cache` - 2 GB

**Persistent Cache Directories:**
- `/var/cache/pacman` - Package manager cache
- `/var/cache/xbps` - Package manager cache (Void)
- `/home/$USER/.cache/paru` - AUR helper cache
- `/home/$USER/.cache/nvidia` - NVIDIA shader cache
- `/home/$USER/.cache/mesa_shader_cache` - Mesa shader cache
- `/home/$USER/.cache/mesa_shader_cache_db` - Mesa shader database

These directories are bind-mounted from disk into the TMPFS above them, so they persist across reboots while the rest of the cache doesn't.

*RAM Overlay of System Directories:*
- `/etc` - System configuration files
- `/var/log` - System logs
- Each directory is mounted as an OverlayFS: the real directory becomes the lower layer and a RAM-backed upper layer, limited to 50% of RAM, absorbs all writes. Changes sync back to disk every 5 minutes, `/etc` also syncs within 30 seconds of a write and a final sync runs at logout and shutdown. Changes that haven't synced yet are lost on a crash or power cut.

*Excluded Directories:*
- `/home` - User data
- `/tmp`, `/var/tmp`, `/var/cache` - Already on TMPFS
- `/proc`, `/sys`, `/dev`, `/run` - Virtual/runtime filesystems
- `/mnt`, `/media`, `/boot` - Mount points and boot files

**Automatic Garbage Collection:**
* Every 30 seconds, files that haven't been modified for 5 minutes are deleted from the TMPFS mounts; the persistent cache directories are left alone
* File-in-use detection (via `lsof`, falling back to `fuser` or `/proc`) ensures open files are never deleted
* Reduces RAM pressure and keeps the TMPFS mounts from filling up

### Network Management
Network performance leverages `BBR` congestion control and `fq` queue management, larger socket buffers and TCP Fast Open to improve throughput and reduce latency. IPv6 is limited: DNS answers contain no IPv6 (AAAA) records, so connections to named hosts use IPv4 and IPv6 uses temporary addresses and ignores redirects and router preferences. NetworkManager uses its internal DHCP client, doesn't send the hostname to DHCP servers (NetworkManager 1.52 or newer) and uses a new random MAC address for every connection at every boot, so expect a new IP address after each reboot and repeated captive-portal logins. On top of UFW's default rules, incoming TCP ports 22 (rate-limited), 80 and 443 are allowed and other incoming connections are dropped; ULU doesn't install an SSH or web server.

**DNS:** Programs that use the system resolver go through DNSMasq to DNSCrypt Proxy, which sends queries over DNS-over-HTTPS to LibreDNS's ad-blocking `libredns-noads` server. Programs with their own DNS-over-HTTPS setting, such as some browsers, bypass it.

### Filesystem & I/O Optimization
Disk and SSD performance is tuned through scheduler and queue optimizations. NVMe drives use `kyber`, which keeps read latency low while writes are in flight; SATA SSDs use `mq-deadline`; and HDDs use `bfq` for fairness under mixed workloads. Read-ahead is set to 128 KB for NVMe and 2048 KB for SATA drives. The I/O queue depth is 2048 for SATA SSDs and 128 for HDDs, while NVMe drives use the kernel's default for a scheduled queue (256 on most drives). I/O request merging stays enabled to combine adjacent requests. On desktops, SATA links stay at `max_performance` link power management and spinning drives get `hdparm -B 254 -S 0`, so they don't spin down; TLP handles both on laptops. Drives mounted through udisks2, such as USB drives, use `noatime`.

**TRIM:** `rc.local` runs `fstrim` on ext4, XFS, Btrfs and F2FS filesystems whose device supports discard (also through LUKS or LVM when discards are passed through) if the last successful TRIM was at least 7 days ago. This reclaims unused blocks to preserve SSD longevity and prevent write performance degradation.

**Logging:** On systemd, the journal is kept in RAM instead of on disk, so logs from earlier boots are not kept; a later drop-in such as `/etc/systemd/journald.conf.d/99-local.conf` overrides this. Panic and oops logs the kernel saves in UEFI variables (pstore) are moved to disk at the next boot instead of accumulating in the firmware's NVRAM: to `/var/lib/systemd/pstore` by `systemd-pstore` on systemd and to `/var/lib/pstore` by `rc.local` on other inits.

### CPU Architecture Detection & ALHP Package Integration
On Arch-based systems, the installer detects whether the CPU supports x86-64-v3 or v4 and adds the matching ALHP repositories, which provide Arch packages rebuilt for those levels. They take priority over core, extra and multilib on Arch and over Arch's extra and multilib on Artix, whose own repositories stay as they are. Packages ALHP doesn't rebuild still come from the standard repositories.

## Optional Workload-Specific Presets
The presets below can be chosen by running the `optional` command post-installation.

### Performance
**Maximum performance:** CPU vulnerability mitigations, ASLR, KASLR, all the Linux security modules and kernel auditing are turned off and kernel limits such as inotify watches and IPC message sizes are raised. A separate AMD version adds AMD-specific kernel parameters and environment variables.

### Server
**Small-scale NAS and hosting:** a server-oriented `sysctl.conf`, with ZFS loaded at boot.

### LLM
**LLM workloads:** unlimited locked memory and memory overcommit, with CPU vulnerability mitigations and the Linux security modules turned off.

## Contact and Donations
* [Email](mailto:michaelsebero@disroot.org)
* [PayPal](https://www.paypal.com/donate/?cmd=_donations&business=YYGU9JWJEE2AG)
