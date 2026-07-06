# Native Antigravity Installation & Update Guide for Linux/NixOS

Since there are no standard Debian (`.deb`) or Red Hat (`.rpm`) packages available for Antigravity on Linux, this repository provides a fully decoupled, native, and self-contained installer script. It resolves the official Google releases dynamically, supports local caching for network-independent setups, and configures update wrappers native to your guest VM.

---

## 🚀 Standard Installation

You can run the native installer script directly from your local clone or from inside the mounted shared workspace of your NixOS guest VM:

```bash
# Execute the native installer with the --all flag to install both Antigravity 2.0 and Antigravity IDE:
sudo bash guest/nixos/install_antigravity.sh --all
```

---

## ⚡ Network-Independent Caching (Offline Mode)

To enable rapid, bandwidth-efficient, or completely offline installations (perfect for sandboxed VMs or development environments), the installer automatically searches for pre-downloaded tarballs before contacting Google's remote servers.

### How it Works:
1. When you run `install_antigravity.sh`, it dynamically resolves the latest version from `https://antigravity.google/download`.
2. It then scans the following locations (both absolute and relative) for cached tarballs matching the latest version (or generic names):
   - `/home/nixos/shared/downloads/` (NixOS guest-to-host share)
   - `guest/nixos/../../downloads/` (Relative repository downloads directory)
   - `./downloads/`
   - `/var/tmp/`
   - Current directory `.`
3. **Target Files Scan Pattern**:
   - **Antigravity 2.0**: `Antigravity-${version}.tar.gz` or `Antigravity.tar.gz`
   - **Antigravity IDE**: `Antigravity-IDE-${version}.tar.gz`, `Antigravity IDE-${version}.tar.gz`, `Antigravity-IDE.tar.gz`, or `Antigravity IDE.tar.gz`
4. If a matching file is found, the script **bypasses any network downloads** and performs the installation entirely from the local cache.

---

## ⚙️ Installer Command Reference

The script `install_antigravity.sh` is highly configurable. You can pass the following options:

| Flag / Option | Description |
| :--- | :--- |
| `--desktop` | Install/update Antigravity 2.0 desktop app only (default). |
| `--ide` | Install/update Antigravity IDE only. |
| `--all` | Install/update both Antigravity 2.0 desktop and Antigravity IDE. |
| `--cli` | Run Google's official Antigravity CLI installer. |
| `--no-nautilus` | Skip installing the GNOME Files/Nautilus context-menu open integration. |
| `--no-apt` | Do not install dependencies automatically via `apt` (safely skipped on NixOS). |
| `--force` | Force reinstall even when the recorded installed version matches the latest. |
| `--status` | Show installed applications and their versions. |
| `--print-downloads` | Fetch and print the dynamically resolved official Google download URLs. |
| `--uninstall` | Remove all helper-managed files safely from your system. |
| `-y`, `--yes` | Non-interactive execution; assume yes to prompts. |

---

## 🔄 Upkeeping and Updates

Once installed, the utility provides system-wide CLI wraps to manage updates natively:

* **Show Status**:
  ```bash
  antigravity-linux --status
  ```
* **Update both apps**:
  ```bash
  sudo antigravity-linux update --all
  ```
* **Update Desktop app only**:
  ```bash
  sudo update-antigravity
  ```
* **Update IDE app only**:
  ```bash
  sudo update-antigravity-ide
  ```

### Smart Updates:
The `antigravity-linux` CLI wrapper stores the path of the original installation script (e.g. `/home/nixos/shared/guest/nixos/install_antigravity.sh`). When you run an update, it executes your local script directly, fully utilizing any local cached files and keeping your system updated without contacting third-party repositories or downloading duplicate archives.
