# Clean machine deployment

Recommended order:

```text
1. Install/verify normal NVIDIA driver
2. Install_EFI_Boot.cmd
3. reboot through CMP40HX Unlock
4. RunOnce.cmd
5. verify Gen2 x16
6. Install_Auto.cmd
7. reboot
8. Status.cmd
```

Do not install the automatic Windows task before the one-time `RunOnce.cmd`
validation has passed on that machine.

The UEFI installer does not replace Microsoft's Windows Boot Manager file. It
adds a separate firmware entry that points at `\EFI\CMP40HX\40HXUNLK.EFI`.

## Safe uninstall behavior

`Uninstall_Auto.cmd` only removes the Windows scheduled task/runtime state.
It does not delete the EFI GUID record.

`Remove_EFI_Boot.cmd` uses the recorded GUID and never guesses another firmware
entry by display name.

`Uninstall_All.cmd` removes the EFI entry first, then the Windows task. BCD and
firmware snapshots are retained under `C:\ProgramData\CMP40HXGen2\efi`.
