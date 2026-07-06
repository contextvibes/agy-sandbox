# Contributing to agy-sandbox

Thank you for your interest in contributing to **agy-sandbox**! This guide will help you get started.

## How to Contribute

### Reporting Bugs

If you find a bug, please [open an issue](../../issues/new) with:

- A clear, descriptive title
- Steps to reproduce the issue
- Expected vs. actual behavior
- Your environment details (macOS version, Apple Silicon chip model, VM type)

> [!IMPORTANT]
> **Found a security vulnerability?** Do not open a public issue. Please follow the [Security Policy](SECURITY.md) for responsible disclosure.

### Suggesting Features

Feature requests are welcome! Please [open an issue](../../issues/new) describing:

- The problem you're trying to solve
- Your proposed solution
- Any alternative approaches you've considered

### Submitting Pull Requests

1. Fork the repository
2. Create a feature branch from `main` (`git checkout -b feature/my-feature`)
3. Make your changes following the code style guidelines below
4. Commit using [Conventional Commits](#commit-messages) format
5. Push your branch and open a Pull Request
6. Fill out the PR template checklist

## Development Setup

### Prerequisites

See [README.md § Prerequisites](README.md#prerequisites) for hardware and software requirements. Additionally, install:

- **ShellCheck** — `brew install shellcheck` (required for linting shell scripts)

### Getting Started

```bash
# Clone the repository
git clone https://github.com/contextvibes/agy-sandbox.git
cd agy-sandbox

# Verify Xcode CLI tools are installed
xcode-select -p

# Compile all Swift runners
swiftc -O -parse-as-library host/runners/nixos_runner.swift -o host/runners/nixos_runner
swiftc -O -parse-as-library host/runners/macos_runner.swift -o host/runners/macos_runner
swiftc -O -parse-as-library host/runners/compact_image.swift -o host/runners/compact_image

# Codesign VM runners with Virtualization entitlement (required to launch VMs)
codesign --entitlements host/runners/entitlements.plist --force -s - host/runners/nixos_runner
codesign --entitlements host/runners/entitlements.plist --force -s - host/runners/macos_runner

# Run ShellCheck on all shell scripts
find host/ guest/ -name '*.sh' -exec shellcheck {} +
```

## Code Style

### Shell Scripts (`.sh`)

- All scripts **must** begin with `set -euo pipefail` after the shebang
- All scripts **must** pass [ShellCheck](https://www.shellcheck.net/) with zero warnings
- Use 2-space indentation
- Use `"${VARIABLE}"` quoting — never unquoted expansions
- Sanitize all external input parameters with regex validation (e.g., `[[ ! "${INPUT}" =~ ^[a-zA-Z0-9_-]+$ ]]`)
- No hardcoded user-specific paths (e.g., `/Users/someuser`); use `$HOME`, `$USER`, or `dirname` resolution

### Swift Files (`.swift`)

- Follow [Apple Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/)
- Use 2-space indentation
- All runners must support CLI argument parsing via manual `CommandLine.arguments` processing

### General

- UTF-8 encoding, LF line endings
- Trim trailing whitespace
- Insert final newline in all files

### Python Files (`.py`)

- Follow [PEP 8](https://peps.python.org/pep-0008/) style conventions
- Use 4-space indentation
- Target Python 3.x — no Python 2 compatibility required

### Nix Files (`.nix`)

- Use 2-space indentation
- Keep `flake.nix` inputs minimal — justify new dependencies in the PR description

## Context Boundaries

> [!CAUTION]
> **This is the most critical architectural rule in agy-sandbox.**

The repository is strictly divided by **execution context**:

| Directory | Runs On | Never Runs On |
|---|---|---|
| `host/` | macOS Host (bare metal) | Inside any VM |
| `guest/nixos/` | Inside NixOS Guest VM | On the host |
| `guest/macos/` | Inside macOS Guest VM | On the host |

**Violating context boundaries will cause failures, data loss, or security issues.** Every contribution must respect this separation. If your change touches both host and guest code, clearly document which parts run where.

## Architecture

> [!IMPORTANT]
> **ARM64 / aarch64 only.** This project targets Apple Silicon exclusively. Never introduce x86_64 binaries, images, or emulation paths.

- All VM images must be ARM64/aarch64
- All compiled binaries target `arm64-apple-macos`
- No Rosetta 2 or x86_64 translation layers

## Commit Messages

This project follows [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/):

```
<type>(<scope>): <description>

[optional body]

[optional footer(s)]
```

### Types

| Type | Description |
|---|---|
| `feat` | New feature |
| `fix` | Bug fix |
| `docs` | Documentation changes |
| `style` | Formatting, no code change |
| `refactor` | Code restructuring |
| `perf` | Performance improvement |
| `test` | Adding or updating tests |
| `chore` | Maintenance tasks |

### Scopes

Use the execution context as scope: `host`, `guest/nixos`, `guest/macos`, `runners` (for `host/runners/`), `docs` (for documentation-only changes).

### Examples

```
feat(runners): add shared clipboard support to macOS runner
fix(host): sanitize customer name input in boot script
docs(guest/nixos): update installation guide for NixOS 24.11
```

## Pull Request Process

1. **Ensure your PR addresses a single concern** — one feature, one fix, or one refactor per PR
2. **Fill out the PR template checklist** completely
3. **Run ShellCheck** on all modified `.sh` files before submitting
4. **Compile Swift runners** to verify no build errors
5. **Test in the appropriate context** — host scripts on the host, guest scripts inside a VM
6. **Update documentation** if your change affects usage instructions or the `AGENTS.md` orchestration guide
7. A maintainer will review your PR and may request changes
8. Once approved, your PR will be squash-merged into `main`

> [!NOTE]
> **No CI yet.** ShellCheck and compilation checks are manual. Please run them locally before submitting.
>
> **Can't run a guest VM?** If your change affects guest scripts and you cannot test inside a VM, note this in your PR description so reviewers can verify.

## License

By contributing to agy-sandbox, you agree that your contributions will be licensed under the [Apache License 2.0](LICENSE).
