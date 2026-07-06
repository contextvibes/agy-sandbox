# Antigravity Sandbox

![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)
![Platform](https://img.shields.io/badge/Platform-Apple_Silicon-black.svg)
![macOS](https://img.shields.io/badge/macOS-13.0+-brightgreen.svg)

A high-performance isolation sandbox for Apple Silicon — run **macOS** and **NixOS** (Linux ARM64) guest VMs via native `Virtualization.framework`, or isolate workspaces directly on the host. No QEMU, no emulation.

Three modes: **macOS VM** sandboxing with APFS copy-on-write cloning, **NixOS VM** development with direct kernel boot, and **host-level** workspace separation with credential isolation.

---

## Three Isolation Modes

| Mode | What It Does | Best For |
|---|---|---|
| 🍏 **macOS VM** | Full macOS guest on a virtual disk — stateful or stateless (APFS CoW clone) | Customer demos, clean-room environments, macOS app testing |
| ❄️ **NixOS VM** | Linux ARM64 guest with direct kernel boot and declarative NixOS config | Linux development, Electron/Chromium testing, reproducible builds |
| 🏠 **Host Isolation** | Isolated workspace on bare metal via HOME redirection and credential symlinking | Lightweight multi-account separation without VM overhead |

All three modes support **per-customer isolation** — each customer gets their own credentials, workspace, and environment.

---

## Prerequisites

| Requirement | Details |
|---|---|
| **Hardware** | Apple Silicon Mac (M1/M2/M3/M4) |
| **macOS** | 13.0+ (Ventura); 14.0+ recommended for full feature support |
| **Xcode CLI Tools** | `xcode-select --install` (provides `swiftc`, `codesign`) |
| **Python 3** | Required by `sync_downloads.sh`, `add_to_dock.py`, and `create_applet.sh` |
| **Disk Space** | ~20 GB for macOS IPSW, ~2 GB for NixOS ISO, 32–64 GB per VM disk image |

---

## Quick Start

### 1. Set up the shared workspace

All Antigravity workspaces live under `/Users/Shared/<username>/projects/` so they are accessible across macOS user accounts and VM guests.

```bash
# Create the shared project directory (replace <username> with your identifier)
mkdir -p /Users/Shared/<username>/projects
cd /Users/Shared/<username>/projects

# Clone the repository
git clone https://github.com/contextvibes/agy-sandbox.git
cd agy-sandbox
```

### 2. Download assets

```bash
# Download VM dependencies (NixOS ISO, macOS IPSW check, Chrome, Antigravity)
./host/sync_downloads.sh
```

> **Note:** The macOS IPSW restore image (~20 GB) must be downloaded manually from [ipsw.me](https://ipsw.me). `sync_downloads.sh` will tell you which file is expected.

### 3. Boot a VM

Choose one of the following paths:

#### Option A — NixOS Guest (fully automated)

```bash
# Install NixOS (boots installer VM, partitions disk, installs OS automatically)
./host/boot_nixos_installer.sh

# After installation completes, boot the persistent NixOS guest
./host/boot_nixos_guest.sh
```

#### Option B — macOS Guest

```bash
# First time: install macOS from IPSW to create a base image
./host/boot_macos_installer.sh

# Boot directly (no customer isolation)
./host/boot_macos.sh

# Or boot with per-customer isolation (stateful — OS changes persist)
./host/boot_macos.sh --customer mycompany

# Or boot stateless (OS changes discarded on shutdown)
./host/boot_macos.sh --customer mycompany --stateless --retina
```

#### Option C — Host-Level Isolation (no VM)

```bash
# Create an isolated workspace with symlinked credentials
./host/isolate_home_setup.sh /Users/Shared/acme "Acme Corp"

# Create a Dock launcher applet (creates .app + pins to Dock)
./host/create_applet.sh --customer "Acme Corp" --home /Users/Shared/acme

# Launch an isolated shell session (no VM required)
./host/boot_customer_shell.sh --customer acme
```

---

## Directory Structure

```
agy-sandbox/
├── host/                          # Scripts that run on the macOS HOST
│   ├── boot_nixos_installer.sh    # Automated NixOS VM installation
│   ├── boot_nixos_guest.sh        # Boot persistent NixOS guest
│   ├── boot_macos_installer.sh    # macOS VM installation from IPSW
│   ├── boot_macos.sh              # macOS VM boot (direct / stateful / stateless)
│   ├── boot_customer_shell.sh     # Host-level isolated shell (no VM)
│   ├── create_applet.sh           # Dock launcher applet builder
│   ├── sync_downloads.sh          # Asset downloader & audit tool
│   ├── isolate_home_setup.sh      # Customer workspace isolation setup
│   ├── compact_disk_images.sh     # APFS sparse disk compaction
│   ├── add_to_dock.py             # macOS Dock icon management
│   ├── keys/                      # Temporary SSH keys (gitignored)
│   └── runners/                   # Swift hypervisor binaries
│       ├── nixos_runner.swift      # NixOS/Linux VM runner
│       ├── macos_runner.swift      # macOS VM runner
│       ├── compact_image.swift     # APFS hole-punching compactor
│       └── entitlements.plist      # Virtualization.framework entitlement
│
├── guest/                         # Scripts that run INSIDE guest VMs
│   ├── nixos/                     # NixOS system configuration & setup
│   │   ├── configuration.nix      # Full NixOS system declaration
│   │   ├── flake.nix              # Nix flake (nixos-26.05, aarch64-linux)
│   │   ├── install_nixos.sh       # Automated guest installation script
│   │   ├── installation_guide.md  # Manual installation reference
│   │   ├── install_antigravity_guide.md  # Antigravity IDE installation guide
│   │   ├── update_vm.sh           # Rebuild NixOS from updated config
│   │   ├── clean_nixos_guest.sh   # Cleanup & zero-fill for compaction
│   │   ├── install_antigravity.sh # Antigravity IDE installer
│   │   ├── launch_antigravity.sh  # Antigravity IDE launcher
│   │   ├── auto_resize.sh         # Dynamic display auto-resizer
│   │   └── rice_xfce.sh           # XFCE desktop customization
│   └── macos/                     # macOS guest optimization
│       ├── ultimate_cleanup.sh    # Deep cleanup & zero-fill compaction
│       ├── apply_optimizations.sh # Disable heavy UI animations
│       ├── revert_optimizations.sh
│       ├── vm_guest_init.sh       # Guest initialization script
│       ├── com.antigravity.guestinit.plist  # LaunchDaemon for vm_guest_init.sh
│       └── gpu_test.swift         # Metal GPU acceleration test
│
├── downloads/                     # Binary assets — ISOs, IPSWs, DMGs (gitignored)
├── images/                        # VM disk images (gitignored)
└── boot/                          # Extracted kernel/initrd cache (gitignored)
```

> **Strict context boundary:** Everything in `host/` runs on macOS. Everything in `guest/` runs inside VMs. Never mix contexts.

---

## Architecture

### VM Runners

Both runners are pure Swift using Apple's native `Virtualization.framework`:

| Feature | NixOS Runner | macOS Runner |
|---|---|---|
| Boot method | Direct kernel boot (`VZLinuxBootLoader`) | IPSW restore / NVRAM boot |
| Display | SPICE agent + Cocoa window | `VZMacGraphicsDevice` (Retina support) |
| Networking | NAT with stable MAC address | NAT with persistent MAC |
| Sharing | VirtioFS directory mount | VirtioFS ("My Shared Files") |
| Auto-scaling | ½ host cores (2–4), ¼ host RAM (2–8 GB) | ½ host cores (4–8), ¼ host RAM (4–16 GB) |
| Self-healing | Machine ID backup/restore | NVRAM + hardware model + machine ID |

### Isolation Modes

#### macOS VM Isolation

Each customer gets an instant APFS copy-on-write clone of the base macOS image (zero-copy, zero-delay). Three boot modes via `boot_macos.sh`:

| Mode | Command | OS Changes | Customer Data |
|---|---|---|---|
| **Direct** | `boot_macos.sh` | Persist (base image) | Shared |
| **Stateful** | `boot_macos.sh --customer acme` | Persist (per-customer clone) | Isolated |
| **Stateless** | `boot_macos.sh --customer acme --stateless` | Discarded on shutdown | Isolated |

#### NixOS VM Profiles

Named profiles map to separate disk images — each with independent system state:

```bash
./host/boot_nixos_installer.sh antigravity-nixos     # Default profile
./host/boot_nixos_installer.sh myproject-nixos        # Custom profile
./host/boot_nixos_installer.sh devteam-nixos          # Custom profile
```

Each profile creates its own disk image at `images/<profile>.img`.

#### Host-Level Isolation

No VM required. `boot_customer_shell.sh` spawns an interactive shell with HOME redirection, and `isolate_home_setup.sh` creates per-customer home directories with symlinked credentials (GPG, SSH, Git). `create_applet.sh` builds dedicated Dock launcher applets that launch Antigravity or Antigravity IDE in the isolated context.

---

## Common Operations

### Update NixOS configuration

Edit `guest/nixos/configuration.nix` on the host, then inside the running NixOS guest:

```bash
sudo /home/nixos/shared/guest/nixos/update_vm.sh
```

### Compact VM disk images

Guest VMs accumulate deleted file space over time. To reclaim it:

```bash
# Step 1: Zero-fill inside the guest
# NixOS:
sudo /home/nixos/shared/guest/nixos/clean_nixos_guest.sh
# macOS:
sudo ./guest/macos/ultimate_cleanup.sh

# Step 2: Shut down the VM, then compact on the host
./host/compact_disk_images.sh
```

### Set up a new customer workspace

Three steps: create the isolated home, create a Dock launcher applet, and boot a VM.

```bash
# Step 1: Create isolated home directory (symlinks credentials from host)
./host/isolate_home_setup.sh /Users/Shared/acme "Acme Corp"

# Step 2: Create the Dock launcher applet (creates .app, pins to Dock — one command)
./host/create_applet.sh --customer "Acme Corp" --home /Users/Shared/acme

# Step 3: Boot a VM for this customer
./host/boot_macos.sh --customer acme

# Or: boot stateless (OS changes discarded on shutdown)
./host/boot_macos.sh --customer acme --stateless

# Or: launch an isolated shell session instead (no VM)
./host/boot_customer_shell.sh --customer acme
```

`create_applet.sh` handles all the complexity: creates the `.app` bundle in `~/Applications/`, sets `CFBundleName`, compiles the AppleScript launcher (redirects `HOME`/`GEMINI_HOME`/`--user-data-dir`), and pins it to the Dock.

```bash
# Additional options:
./host/create_applet.sh --customer acme --home /Users/Shared/acme --ide      # IDE variant
./host/create_applet.sh --customer acme --home /Users/Shared/acme --no-dock  # Skip Dock pinning
```

### Sync/audit downloaded assets

```bash
./host/sync_downloads.sh
```

Performs a bidirectional audit: checks that all expected files are present and flags any unmanaged orphan files.

---

## NixOS Guest Details

The NixOS configuration (`guest/nixos/configuration.nix`) is specifically tuned for `Virtualization.framework`:

- **XFCE desktop** on X11 with LightDM auto-login
- **VirtIO-GPU** with Mesa/VirGL hardware acceleration
- **IPv6 fully disabled** — prevents Chromium BPF kernel panics in virtualized environments
- **BPF JIT disabled** — forces safe interpreted BPF engine
- **GCE metadata route blocked** — prevents 42-second ADC timeout stalls in Go/Electron apps
- **TCP checksum offloading disabled** — works around Apple NAT bug
- **nix-ld** with full Electron/Chromium library compatibility layer
- **Flakes enabled** with auto-optimise-store and weekly GC

---

## Troubleshooting

| Problem | Solution |
|---|---|
| VM won't start — entitlement error | `codesign --entitlements host/runners/entitlements.plist --force -s - host/runners/<runner>` |
| Electron apps show black screen | Ensure `169.254.169.254` unreachable route is active (configured in `configuration.nix`) |
| Kernel panic in NixOS guest | Verify IPv6 is disabled and BPF JIT is off (configured in `configuration.nix`) |
| Disk images growing too large | Run guest zero-fill then `./host/compact_disk_images.sh` |
| VirtioFS mount not available | Check that `--shared-dir` was passed and guest has mounted the VirtioFS tag |
| Dock applet not launching | Flush preferences cache: `killall cfprefsd && defaults read com.apple.dock >/dev/null && killall Dock` |
| Isolated shell can't find tools | Symlink `.zshenv` and `.nix-profile` from host home to customer directory (see `isolate_home_setup.sh`) |

---

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## Security

To report a vulnerability, please see our [Security Policy](SECURITY.md).

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for details.
