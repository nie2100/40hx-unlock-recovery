# Hardware validation

Target used for v0.1.0 validation:

- ASUS CMP 40HX 8GB, TU106
- PCI ID 10DE:1F0B
- VBIOS 90.06.67.00.04
- Intel HM570 + i7-11850H
- GPU 01:00.0, upstream Root Port 00:01.0
- physical width x16

Validated no-EFI-retrain boot:

```text
[efi-b] Root TLS=Gen2; GPU TLS intentionally unchanged
[efi-b] NO-RETRAIN: TLS2 set; skip EFI retrain
```

After NVIDIA driver bind, before the Windows helper writes:

```text
LINK_CONFIG_0 = 800C5800
PRIV_MISC_1   = E0B40D00
XVE_OVR       = 00000006
CYA_0         = 068731B3
PL_LINK_RATE  = 00220036
VSEC_DEVICE   = 00000801
GPU LNKCAP    = 00453D02
GPU LNKCAP2   = 00000006
GPU TLS       = 2
Root TLS      = 2
Current       = Gen1 x16
```

The production helper restores only:

```text
LINK_CONFIG_0 -> 80085800
PRIV_MISC_1   -> E0B42D00
```

Then Root Retrain SET_ONLY #1 did not enter Link Training, while #2 did:

```text
ROOT2: LT=1, GPU Gen2
ROOT2: LT=0, GPU Gen2, Root Gen2
final: Gen2 x16
```

This demonstrates on the validated platform that EFI-stage retraining is unnecessary. The result does not prove compatibility with every CMP 40HX board/VBIOS/chipset.
