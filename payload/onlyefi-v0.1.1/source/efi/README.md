# EFI production delta

The shipped EFI is the boot-validated native-hook image with **both EFI Root-Port retrains removed**.

Production EFI state machine:

```text
compute unlock
-> 4 x TU106 private Gen2 policy RMW
-> Root LNKCTL2 Target Link Speed = Gen2
-> chainload Windows
```

There is deliberately no Root Retrain #1/#2 in EFI.

`apply_no_efi_retrain.py` is fail-closed: it accepts only the exact validated C-like input image and checks the code bytes before patching. The output hash must match the shipped production EFI.

The full-source integration should implement the same control-flow change at the post-unlock Gen2 hook: retain the four policy RMWs and Root TLS=2, then return/chainload before the first EFI Root retrain.
