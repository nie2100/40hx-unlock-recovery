/*
 * CMP 40HX production minimal-policy post-bind Gen2 helper
 *
 * Production path validated on ASUS CMP 40HX / TU106 after a no-EFI-retrain boot:
 *   1) require the no-retrain EFI policy/materialized Gen2 state to be present after driver bind;
 *   2) restore only LINK_CONFIG_0 and PRIV_MISC_1;
 *   3) issue Root Port Retrain-Link SET-only, poll to settle;
 *   4) if still Gen1, issue the same Root retrain once more;
 *   5) require physical Gen2 x16 on GPU and Root.
 *
 * Explicitly DOES NOT write GPU TLS, Root TLS, XVE_OVR, CYA_0, FLR, D3, SBR,
 * Link Disable, GPU retrain or PnP state.
 *
 * Native x64 PE, no CRT/.NET/PowerShell. PE subsystem/OS version 6.1 for Win7+.
 */

typedef unsigned char      u8;
typedef unsigned short     u16;
typedef unsigned int       u32;
typedef unsigned long long u64;
typedef signed int         s32;
typedef unsigned long long usize;
typedef void* HANDLE;
typedef int BOOL;
typedef unsigned int DWORD;
typedef const char* LPCSTR;
typedef void* LPVOID;
typedef const void* LPCVOID;

#define NULL ((void*)0)
#define INVALID_HANDLE_VALUE ((HANDLE)(long long)-1)
#define GENERIC_READ  0x80000000u
#define GENERIC_WRITE 0x40000000u
#define OPEN_EXISTING 3u
#define STD_OUTPUT_HANDLE ((DWORD)-11)

#define IOCTL_WR_READ_PCI   0x9C406144u
#define IOCTL_WR_WRITE_PCI  0x9C40A148u
#define IOCTL_TS_READ_PHYS  0x80006498u
#define IOCTL_TS_WRITE_PHYS 0x8000649Cu

#define GPU_ID              0x1F0B10DEu
#define TU106_BOOT0         0x166000A1u
#define OFF_LINK_CONFIG_0   0x008C040ull
#define OFF_PRIV_MISC_1     0x008841Cull
#define OFF_XVE_OVR         0x008872Cull
#define OFF_CYA_0           0x008C2C0ull
#define OFF_PL_LINK_RATE    0x008C1C0ull
#define OFF_VSEC_DEVICE     0x008860Cull
#define OFF_SS0             0x0409664ull
#define OFF_SS1             0x040966Cull

#define DRIVER_LINK_CONFIG  0x800C5800u
#define TARGET_LINK_CONFIG  0x80085800u
#define DRIVER_PRIV_MISC    0xE0B40D00u
#define TARGET_PRIV_MISC    0xE0B42D00u

#define EXPECT_XVE_OVR      0x00000006u
#define EXPECT_CYA_0        0x068731B3u
#define EXPECT_PL_RATE      0x00220036u
#define EXPECT_VSEC         0x00000801u
#define EXPECT_SS0          0x88888888u
#define EXPECT_SS1          0x00000008u
#define EXPECT_GPU_LNKCAP   0x00453D02u
#define EXPECT_GPU_LNKCAP2  0x00000006u

/* WinAPI pointers: resolved from the PEB so the image has no import table. */
typedef HANDLE (__attribute__((ms_abi)) *PFN_CreateFileA)(LPCSTR,DWORD,DWORD,LPVOID,DWORD,DWORD,HANDLE);
typedef BOOL   (__attribute__((ms_abi)) *PFN_DeviceIoControl)(HANDLE,DWORD,LPVOID,DWORD,LPVOID,DWORD,DWORD*,LPVOID);
typedef BOOL   (__attribute__((ms_abi)) *PFN_CloseHandle)(HANDLE);
typedef void   (__attribute__((ms_abi)) *PFN_Sleep)(DWORD);
typedef DWORD  (__attribute__((ms_abi)) *PFN_GetLastError)(void);
typedef HANDLE (__attribute__((ms_abi)) *PFN_GetStdHandle)(DWORD);
typedef BOOL   (__attribute__((ms_abi)) *PFN_WriteFile)(HANDLE,LPCVOID,DWORD,DWORD*,LPVOID);
typedef void   (__attribute__((ms_abi)) *PFN_ExitProcess)(u32);

static PFN_CreateFileA pCreateFileA;
static PFN_DeviceIoControl pDeviceIoControl;
static PFN_CloseHandle pCloseHandle;
static PFN_Sleep pSleep;
static PFN_GetLastError pGetLastError;
static PFN_GetStdHandle pGetStdHandle;
static PFN_WriteFile pWriteFile;
static PFN_ExitProcess pExitProcess;
static HANDLE gOut;
static HANDLE gWR;
static HANDLE gTS;

static usize cstrlen(const char *s){ usize n=0; while(s && s[n]) n++; return n; }
static int ceq(const char*a,const char*b){ while(*a&&*b){ if(*a!=*b)return 0; a++;b++; } return *a==*b; }
static char cup(char c){ return (c>='a'&&c<='z')?(char)(c-32):c; }
static int ascii_u16_mod_eq(const char *a, const u16 *w, u16 bytes){
    usize an=cstrlen(a), wn=(usize)bytes/2, i; int req_has_dot=0;
    for(i=0;i<an;i++) if(a[i]=='.') req_has_dot=1;
    if(!req_has_dot){
        if(wn != an+4) return 0;
        for(i=0;i<an;i++) if(cup(a[i]) != cup((char)w[i])) return 0;
        return cup((char)w[an])=='.' && cup((char)w[an+1])=='D' && cup((char)w[an+2])=='L' && cup((char)w[an+3])=='L';
    }
    if(wn!=an) return 0;
    for(i=0;i<an;i++) if(cup(a[i]) != cup((char)w[i])) return 0;
    return 1;
}
static void *get_peb(void){ void *p; __asm__ volatile("movq %%gs:0x60,%0":"=r"(p)); return p; }
static void *find_loaded_module(const char *name){
    u8 *peb=(u8*)get_peb(); if(!peb) return NULL;
    u8 *ldr=*(u8**)(peb+0x18); if(!ldr) return NULL;
    u8 *head=ldr+0x20, *link=*(u8**)head;
    for(int n=0; link && link!=head && n<128; n++, link=*(u8**)link){
        void *base=*(void**)(link+0x20);
        u16 len=*(u16*)(link+0x48);
        u16 *buf=*(u16**)(link+0x50);
        if(base && buf && ascii_u16_mod_eq(name,buf,len)) return base;
    }
    return NULL;
}
static void *resolve_export_mod(void *base, const char *name, int depth);
static void *resolve_forwarder(const char *fwd, int depth){
    if(depth>6) return NULL;
    char mod[96], sym[128]; usize i=0,j=0;
    while(fwd[i] && fwd[i]!='.' && i<sizeof(mod)-1){ mod[i]=fwd[i]; i++; }
    if(fwd[i]!='.') return NULL; mod[i]=0; i++;
    while(fwd[i] && j<sizeof(sym)-1){ sym[j++]=fwd[i++]; } sym[j]=0;
    if(sym[0]=='#') return NULL;
    void *mb=find_loaded_module(mod); if(!mb) return NULL;
    return resolve_export_mod(mb,sym,depth+1);
}
static void *resolve_export_mod(void *base, const char *name, int depth){
    if(!base || depth>6) return NULL; u8 *b=(u8*)base;
    if(*(u16*)b != 0x5A4D) return NULL;
    s32 lfanew=*(s32*)(b+0x3c); if(lfanew<0 || lfanew>0x100000) return NULL;
    u8 *nt=b+lfanew; if(*(u32*)nt!=0x00004550u) return NULL;
    u8 *opt=nt+24; if(*(u16*)opt!=0x20Bu) return NULL;
    u32 erva=*(u32*)(opt+0x70), esz=*(u32*)(opt+0x74); if(!erva||!esz) return NULL;
    u8 *ed=b+erva; u32 nfunc=*(u32*)(ed+20), nname=*(u32*)(ed+24);
    u32 funcs=*(u32*)(ed+28), names=*(u32*)(ed+32), ords=*(u32*)(ed+36);
    if(!funcs||!names||!ords) return NULL;
    u32 *na=(u32*)(b+names); u16 *oa=(u16*)(b+ords); u32 *fa=(u32*)(b+funcs);
    for(u32 i=0;i<nname;i++){
        const char *s=(const char*)(b+na[i]);
        if(ceq(s,name)){
            u16 o=oa[i]; if((u32)o>=nfunc) return NULL;
            u32 rva=fa[o];
            if(rva>=erva && rva<erva+esz) return resolve_forwarder((const char*)(b+rva),depth);
            return b+rva;
        }
    }
    return NULL;
}
static void *resolve_api(const char *mod,const char *name){ void *mb=find_loaded_module(mod); return mb?resolve_export_mod(mb,name,0):NULL; }
static int init_api(void){
    pCreateFileA=(PFN_CreateFileA)resolve_api("KERNEL32.DLL","CreateFileA");
    pDeviceIoControl=(PFN_DeviceIoControl)resolve_api("KERNEL32.DLL","DeviceIoControl");
    pCloseHandle=(PFN_CloseHandle)resolve_api("KERNEL32.DLL","CloseHandle");
    pSleep=(PFN_Sleep)resolve_api("KERNEL32.DLL","Sleep");
    pGetLastError=(PFN_GetLastError)resolve_api("KERNEL32.DLL","GetLastError");
    pGetStdHandle=(PFN_GetStdHandle)resolve_api("KERNEL32.DLL","GetStdHandle");
    pWriteFile=(PFN_WriteFile)resolve_api("KERNEL32.DLL","WriteFile");
    pExitProcess=(PFN_ExitProcess)resolve_api("KERNEL32.DLL","ExitProcess");
    if(!pCreateFileA||!pDeviceIoControl||!pCloseHandle||!pSleep||!pGetLastError||!pGetStdHandle||!pWriteFile||!pExitProcess) return 0;
    gOut=pGetStdHandle(STD_OUTPUT_HANDLE); return 1;
}

static void out(const char*s){ if(!pWriteFile||!gOut||gOut==INVALID_HANDLE_VALUE)return; DWORD n=0; pWriteFile(gOut,s,(DWORD)cstrlen(s),&n,NULL); }
static char *app(char *p,const char*s){ while(*s)*p++=*s++; return p; }
static char hx(u8 v){ return v<10?(char)('0'+v):(char)('A'+v-10); }
static char *hex2(char*p,u8 v){*p++=hx(v>>4);*p++=hx(v&15);return p;}
static char *hex4(char*p,u16 v){for(int i=3;i>=0;i--)*p++=hx((u8)((v>>(i*4))&15));return p;}
static char *hex8(char*p,u32 v){for(int i=7;i>=0;i--)*p++=hx((u8)((v>>(i*4))&15));return p;}
static char *hex16(char*p,u64 v){for(int i=15;i>=0;i--)*p++=hx((u8)((v>>(i*4))&15));return p;}
static char *dec(char*p,u32 v){char t[16];int n=0;do{t[n++]=(char)('0'+v%10);v/=10;}while(v);while(n)*p++=t[--n];return p;}
static void line_u32(const char*tag,u32 v){char z[160],*p=z;p=app(p,tag);p=app(p,"0x");p=hex8(p,v);*p++='\r';*p++='\n';*p=0;out(z);}
static void line_u64(const char*tag,u64 v){char z[180],*p=z;p=app(p,tag);p=app(p,"0x");p=hex16(p,v);*p++='\r';*p++='\n';*p=0;out(z);}
static void line_bdf(const char *tag,u8 b,u8 d,u8 f){char z[128],*p=z;p=app(p,tag);p=hex2(p,b);*p++=':';p=hex2(p,d);*p++='.';*p++=(char)('0'+f);*p++='\r';*p++='\n';*p=0;out(z);}
static void line_state(const char *tag,u16 st){char z[180],*p=z;p=app(p,tag);p=app(p," Gen");p=dec(p,st&0xF);p=app(p," x");p=dec(p,(st>>4)&0x3F);p=app(p," LNKSTA=0x");p=hex4(p,st);*p++='\r';*p++='\n';*p=0;out(z);}
static void line_pair(const char*tag,u32 old,u32 req,u32 rb){char z[220],*p=z;p=app(p,tag);p=app(p," old=");p=hex8(p,old);p=app(p," req=");p=hex8(p,req);p=app(p," rb=");p=hex8(p,rb);*p++='\r';*p++='\n';*p=0;out(z);}

static u32 pci_bdf(u8 bus,u8 dev,u8 fn){ return ((u32)bus<<8)|((u32)dev<<3)|fn; }
static int pci_read32(u32 bdf,u32 reg,u32*v){u32 in[2]={bdf,reg},o=0,n=0; if(!pDeviceIoControl(gWR,IOCTL_WR_READ_PCI,in,8,&o,4,&n,NULL)||n!=4)return 0;*v=o;return 1;}
static int pci_write16(u32 bdf,u32 reg,u16 v){u8 in[10];u32 n=0;*(u32*)(in+0)=bdf;*(u32*)(in+4)=reg;*(u16*)(in+8)=v;return pDeviceIoControl(gWR,IOCTL_WR_WRITE_PCI,in,10,NULL,0,&n,NULL)!=0;}
static int ts_read32(u64 phys,u32*v){u32 o=0,n=0; if(!pDeviceIoControl(gTS,IOCTL_TS_READ_PHYS,&phys,8,&o,4,&n,NULL)||n!=4)return 0;*v=o;return 1;}
static int ts_write32(u64 phys,u32 v){u8 in[12];u32 n=0;*(u64*)(in+0)=phys;*(u32*)(in+8)=v;return pDeviceIoControl(gTS,IOCTL_TS_WRITE_PHYS,in,12,NULL,0,&n,NULL)!=0;}

typedef struct{u8 bus,dev,fn;u32 bdf;} BDF;
static int find_gpu(BDF*g){
    for(u32 bus=0;bus<256;bus++) for(u32 dev=0;dev<32;dev++) for(u32 fn=0;fn<8;fn++){
        u32 a=pci_bdf((u8)bus,(u8)dev,(u8)fn),id=0xFFFFFFFFu;
        if(!pci_read32(a,0,&id)||id==0xFFFFFFFFu){ if(fn==0) break; else continue; }
        if(id==GPU_ID){g->bus=(u8)bus;g->dev=(u8)dev;g->fn=(u8)fn;g->bdf=a;return 1;}
        if(fn==0){u32 h=0;if(!pci_read32(a,0x0C,&h)||(((h>>16)&0x80)==0))break;}
    }
    return 0;
}
static u32 find_cap(u32 bdf,u8 want){
    u32 h=0;if(!pci_read32(bdf,0x34,&h))return 0;u32 cur=h&0xFFu;u8 seen[64];for(int i=0;i<64;i++)seen[i]=0;
    for(int n=0;n<48;n++){
        if(cur<0x40||cur>0xFC||seen[(cur&0xFC)>>2])return 0; seen[(cur&0xFC)>>2]=1;
        u32 c=0;if(!pci_read32(bdf,cur,&c))return 0;if((c&0xFFu)==want)return cur;cur=(c>>8)&0xFFu;
    }
    return 0;
}
static int find_root(u8 gpuBus,BDF*r){
    for(u32 bus=0;bus<256;bus++) for(u32 dev=0;dev<32;dev++) for(u32 fn=0;fn<8;fn++){
        u32 a=pci_bdf((u8)bus,(u8)dev,(u8)fn),id=0xFFFFFFFFu;
        if(!pci_read32(a,0,&id)||id==0xFFFFFFFFu){ if(fn==0) break; else continue; }
        u32 cls=0;if(!pci_read32(a,0x08,&cls))continue;
        if(((cls>>16)&0xFFFFu)==0x0604u){u32 bn=0;if(pci_read32(a,0x18,&bn)&&(((bn>>8)&0xFFu)==gpuBus)){r->bus=(u8)bus;r->dev=(u8)dev;r->fn=(u8)fn;r->bdf=a;return 1;}}
        if(fn==0){u32 h=0;if(!pci_read32(a,0x0C,&h)||(((h>>16)&0x80)==0))break;}
    }
    return 0;
}
static int get_bar0(u32 gpu,u64*bar){u32 lo=0,hi=0;if(!pci_read32(gpu,0x10,&lo)|| (lo&1))return 0;u64 b=(u64)(lo&0xFFFFFFF0u);if((lo&0x6u)==0x4u){if(!pci_read32(gpu,0x14,&hi))return 0;b|=((u64)hi<<32);}*bar=b;return b!=0;}
static u16 linksta(u32 bdf,u32 cap){u32 v=0;if(!pci_read32(bdf,cap+0x10,&v))return 0;return (u16)(v>>16);}
static u32 tls(u32 bdf,u32 cap){u32 v=0;if(!pci_read32(bdf,cap+0x30,&v))return 0xFFFFFFFFu;return v&0xFu;}
static int is_gen2_x16(u16 st){return ((st&0xFu)>=2)&&(((st>>4)&0x3Fu)==16);}

static int open_devices(void){
    gWR=pCreateFileA("\\\\.\\WinRing0_1_2_0",GENERIC_READ|GENERIC_WRITE,0,NULL,OPEN_EXISTING,0,NULL);
    if(gWR==INVALID_HANDLE_VALUE){out("ERROR: cannot open \\\\.\\WinRing0_1_2_0. Start WinRing0 driver first.\r\n");return 0;}
    gTS=pCreateFileA("\\\\.\\ThrottleStop",GENERIC_READ|GENERIC_WRITE,0,NULL,OPEN_EXISTING,0,NULL);
    if(gTS==INVALID_HANDLE_VALUE){out("ERROR: cannot open \\\\.\\ThrottleStop. Start ThrottleStop driver first.\r\n");pCloseHandle(gWR);gWR=INVALID_HANDLE_VALUE;return 0;}
    return 1;
}
static void close_devices(void){if(gTS&&gTS!=INVALID_HANDLE_VALUE)pCloseHandle(gTS);if(gWR&&gWR!=INVALID_HANDLE_VALUE)pCloseHandle(gWR);}

static int read_guard(BDF gpu,BDF root,u64 bar,u32 gc,u32 rc,int print){
    u32 boot0=0,linkcfg=0,priv=0,xve=0,cya=0,plr=0,vsec=0,ss0=0,ss1=0,glcap=0,glcap2=0;
    int ok=1;
    ok &= ts_read32(bar+0x0,&boot0); ok &= ts_read32(bar+OFF_LINK_CONFIG_0,&linkcfg); ok &= ts_read32(bar+OFF_PRIV_MISC_1,&priv);
    ok &= ts_read32(bar+OFF_XVE_OVR,&xve); ok &= ts_read32(bar+OFF_CYA_0,&cya); ok &= ts_read32(bar+OFF_PL_LINK_RATE,&plr);
    ok &= ts_read32(bar+OFF_VSEC_DEVICE,&vsec); ok &= ts_read32(bar+OFF_SS0,&ss0); ok &= ts_read32(bar+OFF_SS1,&ss1);
    ok &= pci_read32(gpu.bdf,gc+0x0C,&glcap); ok &= pci_read32(gpu.bdf,gc+0x2C,&glcap2);
    u16 gs=linksta(gpu.bdf,gc),rs=linksta(root.bdf,rc);u32 gt=tls(gpu.bdf,gc),rt=tls(root.bdf,rc);
    if(print){
        line_u32("BOOT0=",boot0); line_u32("LINK_CONFIG_0=",linkcfg); line_u32("PRIV_MISC_1=",priv); line_u32("XVE_OVR=",xve);
        line_u32("CYA_0=",cya); line_u32("PL_LINK_RATE=",plr); line_u32("VSEC_DEVICE=",vsec); line_u32("SS0=",ss0); line_u32("SS1=",ss1);
        line_u32("GPU LNKCAP=",glcap); line_u32("GPU LNKCAP2=",glcap2); line_state("GPU:",gs); line_state("ROOT:",rs);
        {char z[128],*p=z;p=app(p,"TLS GPU=");p=dec(p,gt);p=app(p," ROOT=");p=dec(p,rt);*p++='\r';*p++='\n';*p=0;out(z);}
    }
    if(!ok) return 0;
    if(boot0!=TU106_BOOT0 || xve!=EXPECT_XVE_OVR || cya!=EXPECT_CYA_0 || plr!=EXPECT_PL_RATE || vsec!=EXPECT_VSEC || ss0!=EXPECT_SS0 || ss1!=EXPECT_SS1) return 0;
    if(glcap!=EXPECT_GPU_LNKCAP || glcap2!=EXPECT_GPU_LNKCAP2 || gt!=2 || rt!=2) return 0;
    if(((gs>>4)&0x3Fu)!=16 || ((rs>>4)&0x3Fu)!=16) return 0;
    if(!((linkcfg==DRIVER_LINK_CONFIG)||(linkcfg==TARGET_LINK_CONFIG))) return 0;
    if(!((priv==DRIVER_PRIV_MISC)||(priv==TARGET_PRIV_MISC))) return 0;
    return 1;
}

static int restore_policy(u64 bar){
    u32 old=0,rb=0;
    if(!ts_read32(bar+OFF_LINK_CONFIG_0,&old)) return 0;
    if(old!=TARGET_LINK_CONFIG){ if(old!=DRIVER_LINK_CONFIG)return 0; if(!ts_write32(bar+OFF_LINK_CONFIG_0,TARGET_LINK_CONFIG))return 0; }
    if(!ts_read32(bar+OFF_LINK_CONFIG_0,&rb)||rb!=TARGET_LINK_CONFIG)return 0; line_pair("LINK_CONFIG_0",old,TARGET_LINK_CONFIG,rb);
    if(!ts_read32(bar+OFF_PRIV_MISC_1,&old)) return 0;
    if(old!=TARGET_PRIV_MISC){ if(old!=DRIVER_PRIV_MISC)return 0; if(!ts_write32(bar+OFF_PRIV_MISC_1,TARGET_PRIV_MISC))return 0; }
    if(!ts_read32(bar+OFF_PRIV_MISC_1,&rb)||rb!=TARGET_PRIV_MISC)return 0; line_pair("PRIV_MISC_1  ",old,TARGET_PRIV_MISC,rb);
    return 1;
}

/* Exact TPTP semantics: SET_ONLY, no explicit clear, no pre-delay. */
static int retrain_set_only(u32 root,u32 rcap,const char*tag){
    u32 v=0;if(!pci_read32(root,rcap+0x10,&v)){out("ERROR: Root LNKCTL read failed\r\n");return 0;}
    u16 old=(u16)(v&0xFFFFu),req=(u16)(old|0x20u);
    if(!pci_write16(root,rcap+0x10,req)){out("ERROR: Root Retrain-Link write failed\r\n");return 0;}
    u32 rb=0;pci_read32(root,rcap+0x10,&rb);
    {char z[200],*p=z;p=app(p,tag);p=app(p," SET_ONLY old=");p=hex4(p,old);p=app(p," req=");p=hex4(p,req);p=app(p," rb=");p=hex4(p,(u16)(rb&0xFFFF));*p++='\r';*p++='\n';*p=0;out(z);}
    return 1;
}

static int poll_settle(u32 root,u32 rcap,u32 gpu,u32 gcap,const char*tag){
    int saw=0,quiet=0,reads=0;u32 elapsed=0;u16 last=0xFFFFu;u32 lastGG=0xFFFFFFFFu;
    while(elapsed<800){
        u16 rs=linksta(root,rcap),gs=linksta(gpu,gcap);int training=(rs&0x0800u)!=0;u32 gg=gs&0xFu;
        reads++; if(training)saw=1;
        if(reads==1 || rs!=last || gg!=lastGG){
            char z[220],*p=z;p=app(p,tag);p=app(p," poll LT=");p=dec(p,(u32)training);p=app(p," ROOT_GEN=");p=dec(p,rs&0xFu);p=app(p," GPU_GEN=");p=dec(p,gg);p=app(p," LNKSTA=");p=hex4(p,rs);*p++='\r';*p++='\n';*p=0;out(z);
        }
        last=rs;lastGG=gg;
        if(!training && elapsed>=8) quiet++; else quiet=0;
        if(quiet>=12){
            char z[180],*p=z;p=app(p,tag);p=app(p," settled saw_LT=");p=dec(p,(u32)saw);p=app(p," reads=");p=dec(p,(u32)reads);*p++='\r';*p++='\n';*p=0;out(z);return 1;
        }
        pSleep(1); elapsed++;
    }
    out("WARN: Link Training poll timeout; continuing to final state check\r\n"); return 1;
}

static int run(void){
    out("=== CMP40HX Production Gen2 v0.1.0 (minimal validated path) ===\r\n");
    out("EFI retrain: none. Windows restores LINK_CONFIG_0 + PRIV_MISC_1 only, then Root Retrain SET-only up to x2.\r\n");
    out("No TLS writes / no GPU retrain / no PnP / no FLR / no D3 / no SBR / no Link Disable.\r\n\r\n");
    if(!open_devices()) return 10;

    BDF gpu,root;int found=0;
    for(int i=0;i<240;i++){if(find_gpu(&gpu)&&find_root(gpu.bus,&root)){found=1;break;}if(i==0)out("Waiting for GPU/Root Port...\r\n");pSleep(500);}    
    if(!found){out("ERROR: 10DE:1F0B or upstream Root Port not found after 120 s\r\n");close_devices();return 11;}
    line_bdf("GPU=",gpu.bus,gpu.dev,gpu.fn);line_bdf("ROOT=",root.bus,root.dev,root.fn);
    u32 gc=find_cap(gpu.bdf,0x10),rc=find_cap(root.bdf,0x10);if(!gc||!rc){out("ERROR: PCIe capability not found\r\n");close_devices();return 12;}
    u64 bar=0;if(!get_bar0(gpu.bdf,&bar)){out("ERROR: BAR0 decode failed\r\n");close_devices();return 13;}line_u64("BAR0=",bar);

    /* If driver is still taking over, wait until the exact validated post-bind state appears. */
    int guard=0;
    for(int i=0;i<240;i++){
        u16 gs=linksta(gpu.bdf,gc),rs=linksta(root.bdf,rc);
        if(is_gen2_x16(gs)&&is_gen2_x16(rs)){out("PASS: already physical Gen2 x16; no writes needed.\r\n");close_devices();return 0;}
        if(read_guard(gpu,root,bar,gc,rc,0)){guard=1;break;}
        if(i==0)out("Waiting for validated post-driver state...\r\n");pSleep(500);
    }
    if(!guard){out("ERROR: validated post-driver baseline not reached. Refusing writes.\r\n--- observed state ---\r\n");read_guard(gpu,root,bar,gc,rc,1);close_devices();return 14;}
    out("GUARD=PASS\r\n");read_guard(gpu,root,bar,gc,rc,1);

    out("\r\n[1] Restore only the two driver-clobbered policy registers\r\n");
    if(!restore_policy(bar)){out("ERROR: policy restore failed or unexpected baseline; aborting before retrain.\r\n");close_devices();return 15;}

    out("\r\n[2] Root Retrain #1 (SET_ONLY)\r\n");
    if(!retrain_set_only(root.bdf,rc,"ROOT1")){close_devices();return 16;}poll_settle(root.bdf,rc,gpu.bdf,gc,"ROOT1");
    u16 gs=linksta(gpu.bdf,gc),rs=linksta(root.bdf,rc);line_state("GPU after ROOT1:",gs);line_state("ROOT after ROOT1:",rs);
    if(is_gen2_x16(gs)&&is_gen2_x16(rs)){out("PASS: physical Gen2 x16 reached on ROOT1.\r\n");close_devices();return 0;}

    out("\r\n[3] Root Retrain #2 (SET_ONLY)\r\n");
    if(!retrain_set_only(root.bdf,rc,"ROOT2")){close_devices();return 17;}poll_settle(root.bdf,rc,gpu.bdf,gc,"ROOT2");
    gs=linksta(gpu.bdf,gc);rs=linksta(root.bdf,rc);line_state("GPU final:",gs);line_state("ROOT final:",rs);
    if(is_gen2_x16(gs)&&is_gen2_x16(rs)){out("PASS: physical Gen2 x16 reached.\r\n");close_devices();return 0;}
    out("FAIL: exact validated TPTP path completed but link is not Gen2 x16.\r\n");close_devices();return 24;
}

void __attribute__((ms_abi)) entry(void){if(!init_api())return;int rc=run();pExitProcess((u32)rc);}
