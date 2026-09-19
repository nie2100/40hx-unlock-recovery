# v0.1.1

Installer/packaging release on top of the hardware-validated v0.1.0 core.

## Added

- `Install_EFI_Boot.cmd`
  - backs up BCD;
  - mounts the EFI System Partition;
  - installs `\EFI\CMP40HX\40HXUNLK.EFI`;
  - creates `CMP40HX Unlock`;
  - moves it to the front of UEFI firmware boot order;
  - stores the created GUID for safe removal.
- `Remove_EFI_Boot.cmd`
  - removes only the package-owned NVRAM entry and EFI file.
- `CMP40HX_Manager.cmd`
  - convenience menu for install/test/status/uninstall.
- `Uninstall_All.cmd`
  - removes both the Windows task and the package-owned EFI boot entry.

## Core unchanged

The v0.1.1 EFI image and Windows Gen2 helper are the same production core that
passed manual and automatic cold-boot validation:

```text
UEFI: unlock -> four policy RMWs -> Root TLS=2 -> no EFI retrain -> Windows
Windows: restore LINK_CONFIG_0 + PRIV_MISC_1 -> Root retrain SET_ONLY x1/x2
Final: physical Gen2 x16
```

No new GPU/PCIe research writes were added in v0.1.1.

## Packaging safety fix

EFI installer state and Windows-task state now use separate ProgramData
subdirectories. This prevents `Uninstall_Auto.cmd` from deleting the stored
firmware-entry GUID needed by `Remove_EFI_Boot.cmd`.
