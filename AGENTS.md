# Antigravity Sandbox: Agent Router & Orchestration Guide

A high-performance virtualization sandbox for running macOS and NixOS (Linux ARM64) Guest VMs on Apple Silicon hosts under native `Virtualization.framework`.

---

## 📂 Sandbox Directory Structure

The repository is strictly divided by **execution context** (macOS Host vs. Guest VMs).

```
agy-sandbox/
├── AGENTS.md                    # This orchestration guide
├── host/                        # Executed on the macOS HOST
│   ├── boot_nixos_installer.sh  # Compile, extract, and boot NixOS installer
│   ├── boot_nixos_guest.sh      # Boot persistent installed NixOS guest VM
│   ├── boot_macos_installer.sh  # macOS VM installation from IPSW
│   ├── boot_macos.sh            # macOS VM boot (direct / stateful / stateless)
│   ├── boot_customer_shell.sh   # Host-level isolated shell (no VM)
│   ├── create_applet.sh         # Dock launcher applet builder
│   ├── compact_disk_images.sh   # NixOS/macOS guest image APFS compaction utility
│   ├── sync_downloads.sh        # Idempotent downloader & image audit
│   ├── isolate_home_setup.sh    # Configure isolated customer home sandboxes
│   ├── keys/                    # Temporary SSH keys (gitignored)
│   │   └── id_temp              # Host-to-guest temp SSH key
│   └── runners/                 # Swift hypervisor binaries
│       ├── nixos_runner.swift   # Linux/NixOS VM runner (SPICE/Cocoa UI)
│       ├── macos_runner.swift   # macOS VM runner (SPICE/Cocoa UI)
│       ├── compact_image.swift  # APFS fcntl hole-punching disk compactor
│       ├── compact_image        # Compiled compaction utility
│       └── entitlements.plist   # Codesigning entitlements
│
├── guest/                       # Executed INSIDE the Guest VMs
│   ├── nixos/                   # NixOS VM system declarations & setup
│   │   ├── configuration.nix    # NixOS system config
│   │   ├── flake.nix            # Reproducible Nix flake
│   │   ├── install_nixos.sh     # Install script (guest disk partitioning)
│   │   ├── update_vm.sh         # Rebuild & sync configuration from host
│   │   ├── clean_nixos_guest.sh # Clean up NixOS logs/caches and zero-fill for compaction
│   │   ├── launch_antigravity.sh # Mount host workspace & launch dev tools
│   │   ├── installation_guide.md # Manual installation instructions
│   │   └── init_path.txt        # Cached system init path for kernel boot
│   └── macos/                   # macOS VM slim down & UI tuning
│       ├── cleanup_vm.sh        # Cache/snapshot log trimmer
│       ├── ultimate_cleanup.sh  # Deep 6-phase optimization & zero-fill compaction
│       ├── apply_optimizations.sh # Disable heavy UI animations (CPU rendering)
│       ├── revert_optimizations.sh # Restore default macOS animations
│       └── gpu_test.swift       # Metal GPU acceleration test utility
│
├── downloads/                   # [GITIGNORED] Static mirrors (ISOs, IPSWs, DMGs)
└── images/                      # [GITIGNORED] VM virtual disks (.img) and configs
```

---

## ❄️ NixOS VM Orchestration (Linux ARM64)

Direct-kernel booting via `VZLinuxBootLoader`.

### 1. VM Lifecycle Commands
* **Standard Boot (Installer):** Runs compilation, bootloader extraction, and boots the installer ISO:
  ```bash
  ./host/boot_nixos_installer.sh
  ```
* **Boot Persistent Guest:** Once installed, boots directly from the persistent disk image:
  ```bash
  ./host/boot_nixos_guest.sh
  ```
* **Manual Runner Compilation:**
  ```bash
  swiftc -O -parse-as-library host/runners/nixos_runner.swift -o host/runners/nixos_runner
  ```
* **Update NixOS Config:** (Run from inside guest)
  ```bash
  sudo /home/nixos/shared/guest/nixos/update_vm.sh
  ```

### 2. Linux Runner CLI Interface (`host/runners/nixos_runner`)
```text
  --kernel <path>      # Uncompressed kernel (Image) [Required]
  --initrd <path>      # initrd.img path [Optional]
  --disk <path>        # Can be specified multiple times; ISOs are mounted read-only
  --cpus <count>       # Core allocation (default: 2)
  --memory <MB>        # RAM allocation (default: 2048)
  --cmdline <string>   # Kernel arguments (default: console=hvc0 root=/dev/ram0 rw)
  --gui                # Launches with Cocoa display (SPICE pasteboard sync)
  --width/--height     # GUI window resolution dimensions
```

---

## 🍏 macOS VM Orchestration (Apple Silicon)

Enforces hardware model & machine identifier serialization constraints.

### 1. VM Lifecycle Commands
* **Manual Runner Compilation:**
  ```bash
  swiftc -O -parse-as-library host/runners/macos_runner.swift -o host/runners/macos_runner
  ```
* **Installation Mode (Clean Install from IPSW):** Installs macOS to virtual disk:
  ```bash
  ./host/boot_macos_installer.sh
  ```
* **Direct Boot (No Isolation):** Boots the base macOS image directly:
  ```bash
  ./host/boot_macos.sh
  ```
* **Stateful Customer Mode:** Boots a persistent per-customer APFS clone with isolated workspace:
  ```bash
  ./host/boot_macos.sh --customer <customer> [--retina]
  ```
* **Stateless Customer Mode:** Boots an ephemeral session, OS changes discarded on shutdown:
  ```bash
  ./host/boot_macos.sh --customer <customer> --stateless [--retina]
  ```

### 2. Guest Tuning, Cleanup & Diagnostics
Run these utilities inside the macOS Guest VM to optimize performance under unaccelerated CPU rendering or to test Metal capabilities:
```bash
# Lightweight cleanup (caches, logs, snapshots)
sudo ./guest/macos/cleanup_vm.sh

# Comprehensive 6-phase slimming and zero-fill disk compaction
sudo ./guest/macos/ultimate_cleanup.sh

# Instant visual & window animation speedups (vital for CPU-bound rendering)
./guest/macos/apply_optimizations.sh

# Revert animations to system-default settings
./guest/macos/revert_optimizations.sh

# Run Metal hardware pipeline/compiler diagnostic check
swift ./guest/macos/gpu_test.swift
```

---

## 💎 APFS Virtual Disk Compaction & Space Reclamation

Enables high-performance, in-place disk compaction of Guest VM images (`.img`) on the macOS host without duplicating files, utilizing native APFS `F_PUNCHHOLE` `fcntl` system calls.

### 1. High-Performance Compaction Commands
* **Run Host Compactor Orchestrator:** Automatically checks if images are locked/active, compiles the Swift utility, and punches holes in all zero-filled sectors:
  ```bash
  ./host/compact_disk_images.sh
  ```
* **Compact Specific Image Directly:**
  ```bash
  ./host/runners/compact_image images/macos_<customer>.img
  ```
* **Dry Run (Scan Only - No Hole Punching):**
  ```bash
  ./host/runners/compact_image images/macos_<customer>.img --dry-run
  ```

### 2. Pre-requisite Guest Zero-Filling Steps
For the host compactor to reclaim space, unused sectors inside the Guest VM must first be written with zeroes so they can be identified.
* **NixOS Guest:** Run the high-performance slimming and zero-fill script:
  ```bash
  sudo /home/nixos/shared/guest/nixos/clean_nixos_guest.sh
  ```
* **macOS Guest:** Run the ultimate 6-phase optimization and zero-fill script:
  ```bash
  sudo ./guest/macos/ultimate_cleanup.sh
  ```

---

## ⚡ Asset Synchronization

Synchronize external files (NixOS ISO, macOS IPSW, Chrome, compilers, and platform binaries) and run bidirectional verification audits:
```bash
./host/sync_downloads.sh
```

---

## 🔒 Sandbox Environment Isolation

Configure isolated customer home directories for the Antigravity workspace (linking GPG keychains, SSH configurations, and credentials to prevent cross-contamination):
```bash
./host/isolate_home_setup.sh [target_directory] [display_name]

# Example:
./host/isolate_home_setup.sh /Users/Shared/<customer> "<Display Name>"
```

---

## 🧠 Core Operational Guidelines

1. **Architecture Restrictions:** Target Apple Silicon hosts only. Always use `ARM64 / aarch64` binaries and images; never attempt `x86_64` emulation.
2. **Sparse Allocation Security:** Always allocate virtual disks using `truncate -s` to define disk boundaries instantly without writing blocks, preventing host SSD physical depletion.
3. **Double Serial Console:** When using serial redirection (`console=hvc0`), standard input is consumed by console bindings; use GUI display mode for interactive automated commands.
4. **Strict Context Boundaries:** All scripts in `host/` run exclusively on the host macOS. All scripts in `guest/` run inside Guest VMs. Never mix contexts.
5. **BPF Kernel Socket & JIT Crash Prevention:** Launching Chromium/Electron apps or high-frequency socket events (like UDP DHCP renewals) inside a virtualization guest can trigger sudden kernel panics (null pointer dereferences) in BPF socket filters (`__cgroup_bpf_run_filter_skb` or `sk_filter_trim_cap`). Prevent this by:
   - Completely disabling IPv6 globally and at the kernel sysctl level in the guest configuration.
   - Completely disabling BPF JIT compilation (`net.core.bpf_jit_enable = 0`) at the sysctl level, forcing the kernel to use the safe interpreted BPF engine.
6. **Local Metadata Server (ADC) Connection Timeouts:** Go/Electron applications checking credentials locally can stall for exactly 42+ seconds trying to reach GCE metadata at `169.254.169.254` if the network doesn't explicitly reject the packet. This delay will exceed Electron's default 30-second load timeout and cause a persistent "black screen." Prevent this by adding an unreachable route for `169.254.169.254` on guest boot, forcing these checks to fail instantly (under 1ms).
7. **APFS Copy-on-Write Clones:** When spinning up stateless/disposable guest environments, never use standard `cp` (which duplicates bytes). Use macOS native `cp -c` (on BSD `cp`) or `cp --reflink=auto` (on GNU `cp`) to instantly create copy-on-write sparse file overlays. This guarantees 0ms provisioning times and 0 bytes occupied until modified.
8. **Stateful Multi-Tenant Profile Redirection (Gold Standard):** Do not mount the entire guest `/Users/guest` user home folder directly over paravirtualized filesystems (VirtioFS) because system daemons (`cfprefsd`, databases) require POSIX-compliant flock and socket locks that VirtioFS cannot guarantee. Instead, keep `~/Library` local to the high-performance paravirtualized block device (`.img`), and **symlink only user folders** (`~/Projects`, `~/Desktop`, `~/.ssh`, `~/.gitconfig`, `~/.config`) to the VirtioFS mount. This ensures 100% stability and flawless identity-swapping.
9. **APFS Block-Level Compaction & Hole-Punching:** Standard `rsync -S` or block copies can bloat paravirtualized sparse images by dirtying unused segments. To shrink images, always execute a guest zero-fill sweep, then use Swift's `F_PUNCHHOLE` `fcntl` hole puncher on the host while the image is completely unlocked (VM offline). Note that `F_PUNCHHOLE` requires both the file offset and punch length to be integer multiples of `4096` bytes; passing smaller or unaligned blocks will return `EINVAL` and fail to reclaim space.
10. **Host-Level Graphical Applet Isolation (AppleScript Wrappers):** To run completely isolated graphical instances of Antigravity or Antigravity IDE on bare-metal host macOS, compile independent launcher applets in `~/Applications/Antigravity <customer>.app`. Copy a template applet, update `CFBundleName` in `Info.plist`, and compile a launcher script using macOS native `osacompile` to redirect environment variables and Electron's user data directory to the isolated path:
    ```bash
    osacompile -o "Antigravity <customer>.app/Contents/Resources/Scripts/main.scpt" -e 'do shell script "HOME=\"/Users/Shared/<customer>\" GEMINI_HOME=\"/Users/Shared/<customer>/.gemini\" /Applications/Antigravity.app/Contents/MacOS/Antigravity --user-data-dir=\"/Users/Shared/<customer>/Library/Application Support/Antigravity\" >/dev/null 2>&1 &"'
    ```
11. **macOS Preferences Caching & cfprefsd Flushing:** When editing `com.apple.dock.plist` or other macOS preferences directly on disk (e.g., using Python's `plistlib`), changes will be ignored or overwritten by the in-memory cache daemon `cfprefsd`. To safely apply and render disk preference updates immediately, flush the preferences cache and force a reload using:
    ```bash
    killall cfprefsd && defaults read com.apple.dock >/dev/null && killall Dock
    ```
12. **Full Customer Isolation Requires Three Steps:** The `isolate_home_setup.sh` script only creates the isolated home directory (symlinks, `.config`, Dock plist for the *isolated environment itself*). It does **not** create the host-level AppleScript applet launcher or pin it to the host Dock. When setting up a new isolated customer instance, always perform all three steps in order:
    1. **Create isolated home:** `./host/isolate_home_setup.sh /Users/Shared/<customer> "<Display Name>"`
    2. **Create applet launcher and pin to Dock:** `./host/create_applet.sh --customer "<Display Name>" --home /Users/Shared/<customer>` — this single command creates the `.app` bundle, sets `CFBundleName`, compiles the AppleScript launcher, and pins it to the host Dock.
    3. **For IDE variant:** `./host/create_applet.sh --customer "<Display Name>" --home /Users/Shared/<customer> --ide`

13. **Verified Commits & Git Identity Inheritance:** To prevent "unverified" commit badges on GitHub, the author email must match the email associated with the GPG signing key. Since local `.git/config` settings override global ones, you can force a repository to dynamically inherit the host's verified global credentials (including GPG keys and signing configurations) by unsetting local overrides:
    ```bash
    git config --local --unset user.name
    git config --local --unset user.email
    ```

14. **Nix Toolchain Profile Symlinking under HOME Redirection:** When performing host-level context isolation via `HOME` redirection (e.g. `HOME=/Users/Shared/<customer>`), Zsh will fail to locate Nix-managed tools (such as `gh`, `direnv`, `go`, or `git` helpers) unless both `.zshenv` and `.nix-profile` are symlinked from the host home folder to the customer directory. This is because the Nix daemon initializer in `~/.zshenv` depends on the presence of `$HOME/.nix-profile/bin` to populate the `PATH` variables.

15. **Strict Parameter Sanitization & Path Traversal Shields:** Any script receiving external input arguments that dictate directories or resources (e.g., customer names or profile targets) must strictly sanitize these parameters using regex matching (e.g. `[[ ! "${CUSTOMER}" =~ ^[a-zA-Z0-9_-]+$ ]]`) before referencing them in file paths to prevent directory traversal or file-overwrite bugs.
16. **No Host-Specific or Hardcoded Machine Paths:** Scripts must never contain hardcoded user home directory paths or machine-specific locations unless explicitly falling back to system binaries. Target paths must be relative or resolved dynamically via environment variables like `$HOME`, `$USER`, or `dirname`.
17. **Robust Error Cleanup in Copy-on-Write Fallbacks:** When utilizing copy-on-write overlay clones (`cp -c` or `cp --reflink=auto`), if the operation fails, any partially written corrupt files must be explicitly removed (e.g., `rm -f`) before attempting fallbacks or terminating, preventing file system pollution.
18. Bash Version Compatibility on macOS Hosts: Since macOS defaults to older Bash versions (Bash 3.2.x), scripts intended to execute on macOS hosts must remain compatible. Avoid using Bash 4+ features like associative arrays (`declare -A`). Use standard indexed arrays (`declare -a`) for index-based mapping instead.

19. **Nix-Managed Shell Configuration Isolation & Path Sanitization**: When a user's `.zshrc` or `.zshenv` is managed by Nix (Home Manager), it exists as a read-only symlink in the Nix store. For isolated customer environments, these must be **copied** (not symlinked) and `chmod +w` to allow for local modifications (like `gcloud` paths). Furthermore, any absolute home paths in these configurations must be sanitized to `$HOME` using `sed` to ensure tools like `oh-my-posh` or history logs resolve to the isolated customer directory instead of the main user's home.

20. **Nested Symlink Resolution for Nix Store Detection**: Standard `readlink` only resolves a symlink's first level. In redirected `HOME` environments (such as within the Antigravity editor where `HOME=/Users/Shared/duizendstra`), configuration files like `.zshrc` can point to the host user's profile, which itself is a symlink into `/nix/store/`. Always resolve recursively using `readlink -f` to guarantee that nested symlinks are correctly detected as Nix-managed assets and copied instead of double-symlinked.

21. **Host-Level Preference Modification under HOME Redirection**: When executing scripts inside sandboxes or environments where `HOME` or `~` is redirected to a customer directory, standard path expansion will target the sandbox home. To make changes that affect the host machine's active graphical desktop (such as updating the active macOS Dock), you must explicitly resolve and target the real host user's preference files (e.g., `/Users/<host_user>/Library/Preferences/com.apple.dock.plist`) and restart active systems (`cfprefsd`, `Dock`) for that user.

