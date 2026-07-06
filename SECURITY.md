# Security Policy

## Reporting a Vulnerability

We take the security of **agy-sandbox** seriously. If you discover a security vulnerability, please report it responsibly using **GitHub's private vulnerability reporting** feature.

### How to Report

1. Navigate to the **Security** tab of this repository on GitHub
2. Click **"Report a vulnerability"**
3. Fill out the private advisory form with as much detail as possible

> [!IMPORTANT]
> **Do NOT open a public issue for security vulnerabilities.** Use GitHub's private vulnerability reporting to ensure responsible disclosure.

### What to Include

- A clear description of the vulnerability
- Steps to reproduce the issue
- The potential impact and severity
- Any suggested fixes or mitigations

## Scope

The following areas are considered in-scope for security reports:

| Category | Description |
|---|---|
| **VM Escape** | Any method to break out of a guest VM and execute code on the host |
| **Credential Leakage** | Exposure of SSH keys, GPG keys, API tokens, or other secrets across customer isolation boundaries |
| **Path Traversal** | Exploitation of customer name parameters or file paths to access unauthorized directories in the isolation tooling |
| **Privilege Escalation** | Gaining elevated permissions beyond what the sandbox environment intends to grant |
| **Resource Exhaustion** | A guest VM consuming unbounded host resources (disk via sparse image inflation, CPU, memory) to deny service to the host or other guests |
| **VirtioFS Breakout** | A guest exploiting the VirtioFS shared directory mount to read or write files outside the intended shared directory boundary |

### Out of Scope

- Vulnerabilities in Apple's Virtualization.framework itself (report these to [Apple Security](https://support.apple.com/102549))
- Vulnerabilities in upstream NixOS or macOS guest operating systems
- Issues requiring physical access to the host machine
- Social engineering attacks

## Response Timeline

| Action | Timeframe |
|---|---|
| **Acknowledgment** | Within **48 hours** of report submission |
| **Initial Assessment** | Within **5 business days** |
| **Fix Development** | Dependent on severity and complexity |
| **Public Disclosure** | Coordinated with the reporter after a fix is available |

If you do not receive an acknowledgment within 48 hours, please open a [blank issue](../../issues/new) titled **"Security report acknowledgment"** (without disclosing details) so the maintainers are alerted through a second channel.

## Supported Versions

| Version | Supported |
|---|---|
| Latest release | ✅ |
| Previous releases | ❌ |

We recommend always using the latest version of agy-sandbox.

## Recognition

We appreciate the efforts of security researchers who help keep agy-sandbox safe. With your permission, we will acknowledge your contribution in the release notes of the version containing the fix.

---

*Last reviewed: 2025-07-06*
