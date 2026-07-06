# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-07-06

### Added
- Initial open-source release
- **NixOS VM mode**: Direct kernel boot via `Virtualization.framework` with named profiles
- **macOS VM mode**: Unified `boot_macos.sh` with direct, stateful, and stateless boot modes
- **Host Isolation mode**: Per-customer workspace separation with HOME redirection and Dock applets
- Pure Swift VM runners (`nixos_runner.swift`, `macos_runner.swift`) — no QEMU or emulation
- APFS copy-on-write disk cloning for instant, zero-copy customer provisioning
- APFS hole-punching disk compaction utility (`compact_image.swift`)
- NixOS declarative system configuration tuned for `Virtualization.framework`
- macOS guest optimization and zero-fill compaction scripts
- Bidirectional asset synchronization and audit (`sync_downloads.sh`)
- Antigravity IDE installation and launcher scripts for NixOS guests
