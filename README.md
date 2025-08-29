<p align="center">
	<img src="https://i.postimg.cc/TYCbKN6L/Life.png" width="25%" />
</p>

<p align="center"><strong><font size="12">CoolRune</font></strong> is a High-Performance, Security-Focused Meta-Distribution of Artix Linux</p>

## **CoolRune Includes:**

### **A Modified Kernel & Performance Tools**
* [CachyOS Kernel](https://wiki.cachyos.org/features/kernel/)
* [Earlyoom](https://github.com/rfjakob/earlyoom)
* [GameMode](https://github.com/FeralInteractive/gamemode)

### **Security Software**
* [AppArmor](https://en.wikipedia.org/wiki/AppArmor)
* [Chkrootkit](https://en.wikipedia.org/wiki/Chkrootkit)
* [ClamAV](https://github.com/Cisco-Talos/clamav)
* [DNSCrypt](https://github.com/DNSCrypt/dnscrypt-protocol)
* [Fail2Ban](https://github.com/fail2ban/fail2ban)
* [Linux Hardening Script](https://github.com/Michael-Sebero/Linux-Hardening-Script)
* [Lynis](https://github.com/CISOfy/lynis)
* [USBGuard](https://github.com/USBGuard/usbguard)
* [UFW](https://en.wikipedia.org/wiki/Uncomplicated_Firewall)

### **Tools & Utilities**
* [Arch Package Dictionary](https://github.com/Michael-Sebero/Arch-Package-Dictionary)
* [Archivist Tools](https://github.com/Michael-Sebero/Archivist-Tools)
* [Audio Frequency Tools](https://github.com/Michael-Sebero/Audio-Frequency-Tools)
* [Data Recovery Tools](https://github.com/Michael-Sebero/Data-Recovery-Tools)
* [Document Tools](https://github.com/Michael-Sebero/Document-Tools)
* [Fix Arch Linux](https://github.com/Michael-Sebero/Fix-Arch-Linux)
* [Media Tools](https://github.com/Michael-Sebero/Media-Tools)

### **Additional Features**
* A comprehensive [manual](https://raw.githubusercontent.com/Michael-Sebero/CoolRune/main/files/coolrune-manual/Manual).
* MAC address randomization.
* Configured `sysctl` and `limits` for security enhancements, system performance and network efficiency.
* Low latency [PipeWire](https://github.com/PipeWire/pipewire) audio processing.
* [ALHP](https://wiki.archlinux.org/title/Unofficial_user_repositories#ALHP), [Chaotic-AUR](https://github.com/chaotic-aur/packages) and [Flatpak](https://flatpak.org/) repositories.
* Steam [Proton GE](https://github.com/GloriousEggroll/proton-ge-custom) prefix.
* [ZFS](https://github.com/openzfs/zfs) compatiblity.
* Optional pre-configured PipeWire audio profiles.
* Custom Windows-like XFCE theme.
* [Booster](https://github.com/anatol/booster) (mkinitcpio replacement).
* Battery life optimizations for laptops via [TLP](https://github.com/linrunner/TLP).
* [Mimalloc](https://github.com/microsoft/mimalloc) (high-performance memory allocator).
* Uses tmpfs to speed up temporary directories and reducing disk I/O.

## Performance & Security Expectations
* **10-25%** FPS boost in gaming.
* **15-40%** faster system responsiveness.
* **15-25%** improved network efficiency.
* A Lynis system hardening rating of **80** on desktop and **78** for laptop.

## How CoolRune Works

### Kernel & Security Hardening
CoolRune implements kernel hardening which increases security and performance. The system prevents privilege escalation attacks through restricted ptrace access and disabled unprivileged BPF operations, while eliminating core dump generation to reduce attack surface. Process handling is optimized for high-concurrency workloads with expanded PID limits and disabled automatic NUMA balancing to prevent unnecessary CPU migrations that degrade cache locality.

### Memory Management Optimization
Aggressive memory tuning prioritizes RAM utilization over swap usage, keeping active data in fast memory while optimizing write-back behavior for sustained throughput. The VM subsystem is configured to reduce unnecessary memory compaction overhead while maintaining balanced VFS cache pressure for responsive file operations. HugePages are pre-allocated to eliminate allocation overhead for memory-intensive applications.

**Zram Integration:** The system configures a zram-based swap device (/dev/zram0) to provide fast, compressed virtual memory. Its size is dynamically set to 25% of total RAM. The device is initialized with mkswap and immediately activated with swapon. Compression prioritizes zstd when available, falling back to lzo to maintain low CPU overhead while efficiently storing inactive memory pages. This setup accelerates memory-intensive workloads by reducing disk I/O and keeping more data in RAM.

**TMPFS Overlay Integration:** Critical temporary directories (`/tmp`, `/var/tmp`, `/var/log`) are mounted as tmpfs to leverage RAM for high-speed file storage. Each mount has a predefined size (`/tmp` = 5G, `/var/tmp` = 1G, `/var/log` = 512M). A persistent fallback directory (`/var/tmp/fallback`) is created to handle overflow, with symbolic linking (`/tmp/large_files`) for seamless access. Cleanup routines monitor these directories.

* Periodic cleanup: Removes files older than specified thresholds (5 minutes for /tmp and /var/tmp, 4 hours for the fallback).

* Safe removal: Ensures files in use are never deleted.

* Shutdown cleanup: Fallback directories are cleared on system exit.

### Network Stack Enhancement
Network performance leverages BBR congestion control and fq_codel queue management to improve throughput and reduce latency. The TCP stack uses expanded buffer sizes and enables fast connection establishment. IPv6 is configured with privacy extensions but with restrictive security settings that prioritize security over performance convenience.

### Filesystem & I/O Optimization
Modern I/O patterns are supported through expanded file descriptor limits and asynchronous operation capabilities. The filesystem layer includes enhanced inotify support for file monitoring applications while implementing security protections against symlink and hardlink attacks. These optimizations particularly benefit containerized applications and development environments that require extensive file access patterns.

### Graphics & Gaming Acceleration
Graphics performance is enhanced through threaded shader compilation and caching strategies that reduce stuttering and loading times. Wine and Proton compatibility layers benefit from reduced syscall overhead through event synchronization primitives, while Qt and Chromium applications leverage hardware acceleration and modern rendering techniques for improved responsiveness across desktop and web applications.

### Build System & Development Optimization
Development workflows are accelerated through compiler caching with compression and CPU-specific optimizations that maximize instruction throughput. Thread utilization is optimized for physical core topology rather than logical threads, reducing cache contention and memory bandwidth pressure on SMT-enabled systems while maintaining optimal parallelization for compilation tasks.

### CPU Architecture Detection & ALHP Repository Integration
CoolRune automatically detects CPU architecture on installation to ensure optimal package selection. The system integrates some of ALHP's repositories which provide architecture-specific builds optimized for modern processor capabilities while keeping Artix's core system packages.

### Hardware-Specific Presets
* **AMD/Intel** - Optimized for AMD and Intel CPUs with integrated or discrete graphics, featuring auto-detection for AMD Infinity Fabric or Intel mesh topologies, RDNA/Arc GPU acceleration and enhanced scheduler affinity.

* **NVIDIA** - Configured for NVIDIA GPU acceleration with CUDA optimizations, enhanced memory allocation for GPU computing and driver-specific performance tuning for gaming and machine learning workloads.

* **Laptop** - Balanced between power saving and increased system performance. Includes bluetooth capibility, faster system responsiveness and system hardening. 

### Workload-Specific Presets
* **High Performance** - Maximum throughput configuration with reduced security mitigations, aggressive CPU scheduling, expanded memory limits and enhanced graphics pipeline.

* **Machine Learning/LLM** - Specialized for AI workloads with HugePages allocation, NUMA topology awareness, reduced security mitigations, optimized memory bandwidth utilization and reduced kernel overhead for sustained computational tasks.

* **Server** - Network enhancements tailored for server hardware. Features optimized TCP stack with BBR congestion control, aggressive connection handling (2M TIME_WAIT buckets, fast recycling), enhanced network buffers (16MB socket buffers), comprehensive IPv4/IPv6 filtering with martian packet logging and DDoS mitigation through rate limiting and connection flood protection while maintaining low-latency network performance for high-throughput server applications.

<p align="center">
	<img src="https://i.postimg.cc/C53HDLTZ/ksnip-20240224-100057.png" />

## Donations and Contact
* [PayPal](https://www.paypal.com/donate/?cmd=_donations&business=YYGU9JWJEE2AG)
* [Email](michaelsebero@disroot.org)
