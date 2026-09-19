# CMP40HX Unlock OnlyEFI — v0.1.1

Production release for the hardware-validated ASUS CMP 40HX / TU106 path.

v0.1.1 keeps the **same validated v0.1.0 unlock + Gen2 core** and adds an
automatic UEFI boot-entry installer/remover and a small CMD management menu.

## Validated production state machine

UEFI:

```text
compute unlock
-> four validated TU106 Gen2 policy RMWs
-> upstream Root Port TLS = Gen2
-> chainload Windows
```

There is **no EFI Root-Port retrain**.

Windows after NVIDIA driver bind:

```text
restore LINK_CONFIG_0  800C5800 -> 80085800
restore PRIV_MISC_1    E0B40D00 -> E0B42D00
Root Retrain SET_ONLY #1
if still Gen1: Root Retrain SET_ONLY #2
verify GPU + Root = Gen2 x16
exit
```

The validated Windows path does not write GPU TLS, Root TLS, XVE_OVR or CYA and
does not use GPU retrain, PnP disable/enable, FLR, D3, SBR or Root Link Disable.

## Clean-machine install

1. Boot Windows in UEFI mode.
2. Disable Secure Boot if required by the two low-level reader drivers.
3. Install the normal NVIDIA driver.
4. Extract this release.
5. Run `windows\Install_EFI_Boot.cmd` as Administrator.
6. Reboot. `CMP40HX Unlock` should run first and chainload Windows.
7. Run `windows\RunOnce.cmd` as Administrator.
8. Confirm:
   `PASS: physical Gen2 x16 reached.`
9. Only after the one-time test passes, run `windows\Install_Auto.cmd`.
10. Reboot once more and use `windows\Status.cmd` to confirm task result `0`
    and a final `Gen2 x16` log.

`windows\CMP40HX_Manager.cmd` is only a convenience menu around the same scripts.

## Automatic UEFI boot entry

`Install_EFI_Boot.cmd`:

- exports the current BCD store first;
- snapshots current firmware entries;
- temporarily mounts the EFI System Partition;
- copies `EFI\40HXUNLK.EFI` to `\EFI\CMP40HX\40HXUNLK.EFI`;
- creates a dedicated `CMP40HX Unlock` firmware entry;
- places it first in `{fwbootmgr}` order;
- stores the created GUID in `C:\ProgramData\CMP40HXGen2\efi\efi_boot_guid.txt`;
- unmounts the ESP;
- removes the newly-created entry/file if configuration fails.

It **does not overwrite or delete Windows Boot Manager**.

`Remove_EFI_Boot.cmd` only removes the GUID previously recorded by this package
and the package's own `\EFI\CMP40HX\40HXUNLK.EFI` file.

## Windows automatic task

`Install_Auto.cmd` creates:

```text
Task: CMP40HX Gen2 PostBind
Account: SYSTEM
Trigger: system startup
Runtime: C:\ProgramData\CMP40HXGen2\windows\AutoRetrain.cmd
Log: C:\ProgramData\CMP40HXGen2\windows\logs\last.log
```

The reader services are stopped after the helper exits. Package uninstall only
deletes services/files that the package itself created; pre-existing canonical
services/files are preserved.

## Runtime

- Windows 7 x64 and later target
- native x64 helper
- no PowerShell
- no .NET
- no VC++ runtime
- dynamic CMP 40HX BDF discovery
- dynamic immediate upstream PCIe bridge discovery
- 64-bit BAR0 aware
- strict fail-closed guard before writes

Newer Windows may block the included low-level reader drivers through Secure
Boot, HVCI / Memory Integrity or the Microsoft vulnerable-driver blocklist.

## Hardware validation

Validated target:

- ASUS CMP 40HX 8GB / TU106 A1
- PCI ID `10DE:1F0B`
- Subsystem `1043:8804`
- VBIOS `90.06.67.00.04`
- Intel HM570 + i7-11850H
- physical PCIe width x16

Manual and automatic boot testing both reached physical PCIe Gen2 x16.

See `docs/VALIDATION.md` for the exact state.

## Source

- Windows helper: `source/windows/CMP40HXGen2_prod.c`
- Windows build command: `source/windows/BUILD_CLANG.cmd`
- no-EFI-retrain reproducer: `source/efi/apply_no_efi_retrain.py`
- EFI integration notes: `source/efi/README.md`
- boot-entry scripts: `windows/Install_EFI_Boot.cmd`, `windows/Remove_EFI_Boot.cmd`

## Third-party components

The Release ZIP contains the exact `ThrottleStop.sys` and `WinRing0x64.sys`
binaries used in hardware validation. They are third-party components and are
not claimed as project-authored code. See `THIRD_PARTY_DRIVERS.txt`.

## Persistent state layout

```text
C:\ProgramData\CMP40HXGen2\
├─ efi\
│  ├─ efi_boot_guid.txt
│  ├─ bcd_before_cmp40hx.bcd
│  └─ firmware_before_cmp40hx.txt
└─ windows\
   ├─ CMP40HXGen2.exe
   ├─ AutoRetrain.cmd
   ├─ logs\
   └─ state\
```

EFI and Windows state are intentionally separated so uninstalling the Windows
task cannot destroy the recorded UEFI-entry GUID or BCD backup.
