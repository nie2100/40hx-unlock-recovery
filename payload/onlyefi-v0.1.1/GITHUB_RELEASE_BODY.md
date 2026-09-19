## CMP40HX Unlock OnlyEFI v0.1.1

This release keeps the hardware-validated v0.1.0 unlock/Gen2 core and adds
automatic UEFI boot-entry installation.

### Validated path

- UEFI: compute unlock + four TU106 Gen2 policy RMWs + Root TLS=Gen2.
- **No EFI retrain.**
- After NVIDIA driver bind:
  - `LINK_CONFIG_0: 800C5800 -> 80085800`
  - `PRIV_MISC_1: E0B40D00 -> E0B42D00`
  - Root Retrain SET_ONLY up to two times.
- Validated final link: **PCIe Gen2 x16**.

### New in v0.1.1

- one-command UEFI boot-entry install/remove;
- BCD/firmware snapshot before modification;
- package-owned GUID tracking for safe cleanup;
- convenience CMD manager;
- full uninstall path.

### Install

Run:

```text
windows\Install_EFI_Boot.cmd
```

Reboot, then run:

```text
windows\RunOnce.cmd
```

Only after it reports physical Gen2 x16, install the startup task:

```text
windows\Install_Auto.cmd
```

See `README.md` and `docs/INSTALL.md` for details.
