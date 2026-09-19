#!/usr/bin/env python3
"""
Turn the validated C-like EFI image into the production NO-EFI-RETRAIN image.

Input SHA256:
  e14f354472a3b2a416f0883d052ba694999eb9e9f8a58561db51406f95f0bb85

Output SHA256:
  1e9ca43fab3d5ce851e8fcd09dc9be63282fbf3ce3828c3dbcdcbb21cf7ce1c7

This patch preserves:
- compute unlock
- four TU106 Gen2 policy RMWs
- Root TLS=Gen2

It branches around:
- EFI Root retrain #1
- EFI Root retrain #2
"""
from pathlib import Path
import hashlib, struct, sys

IN_SHA  = "e14f354472a3b2a416f0883d052ba694999eb9e9f8a58561db51406f95f0bb85"
OUT_SHA = "1e9ca43fab3d5ce851e8fcd09dc9be63282fbf3ce3828c3dbcdcbb21cf7ce1c7"

SEC_FILE = 0x8A200
SEC_VA   = 0x140191000
PATCH_VA = 0x140191625
MSG_VA   = 0x140191BC0
EPILOGUE_VA = 0x140191711

EXPECTED_AT_PATCH = bytes.fromhex(
    "8974242c4189f04489e989da4489e6e8b7030000488d0dc007000085c00f84c9"
)

def fo(va): return SEC_FILE + (va - SEC_VA)

def pe_checksum(buf, checksum_offset):
    s=0; n=len(buf); i=0
    while i+1<n:
        w=0 if checksum_offset <= i < checksum_offset+4 else buf[i] | (buf[i+1]<<8)
        s=(s+w)&0xffffffff; s=(s&0xffff)+(s>>16); i+=2
    if i<n:
        w=0 if checksum_offset <= i < checksum_offset+4 else buf[i]
        s=(s+w)&0xffffffff; s=(s&0xffff)+(s>>16)
    s=(s&0xffff)+(s>>16)
    return (s+n)&0xffffffff

if len(sys.argv) != 3:
    raise SystemExit("usage: apply_no_efi_retrain.py INPUT_C_LIKE.EFI OUTPUT.EFI")

src=Path(sys.argv[1]); dst=Path(sys.argv[2])
data=bytearray(src.read_bytes())
if hashlib.sha256(data).hexdigest() != IN_SHA:
    raise SystemExit("refusing patch: input SHA256 does not match validated C-like image")

off=fo(PATCH_VA)
if bytes(data[off:off+len(EXPECTED_AT_PATCH)]) != EXPECTED_AT_PATCH:
    raise SystemExit("refusing patch: expected code bytes do not match")

patch = (
    b"\x48\x8D\x0D" + struct.pack("<i", MSG_VA-(PATCH_VA+7)) +
    b"\xE9" + struct.pack("<i", EPILOGUE_VA-(PATCH_VA+12))
)
data[off:off+12] = patch

msg = "[efi-b] NO-RETRAIN: TLS2 set; skip EFI retrain\n".encode("utf-16le")+b"\x00\x00"
moff=fo(MSG_VA)
data[moff:moff+112] = msg + b"\x00"*(112-len(msg))

peoff=struct.unpack_from("<I",data,0x3c)[0]
csumoff=peoff+24+64
struct.pack_into("<I",data,csumoff,0)
struct.pack_into("<I",data,csumoff,pe_checksum(data,csumoff))

if hashlib.sha256(data).hexdigest() != OUT_SHA:
    raise SystemExit("internal error: output hash does not match expected production image")
dst.write_bytes(data)
print("OK", OUT_SHA, dst)
