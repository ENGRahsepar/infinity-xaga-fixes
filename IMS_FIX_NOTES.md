# IMS / VoLTE Fix Notes — xaga (POCO X4 GT / Redmi K50i / Redmi Note 11T Pro) — Infinity X 4.0-BETA (A17)

**Author:** A.Rahsepar (ENGRahsepar) + OpenCode debugging session 2026-10-16
**Device:** Xiaomi xaga (build spoofed as "Lenovo TB-9707F"), MT6895, Android 17
**Debug channel:** adb over Tailscale (phone 100.67.8.82:5555) + build laptop over SSH

**Symptom:** VoLTE/IMS never registers on Irancell (43235) / MCI (43211).
Works on old 3.12-based builds, works on other A16/A17 ROMs on the same phone + SIM,
broken only on this ROM's A17 builds.

---

## 1. Symptoms (on-device diagnosis)

- `com.mediatek.ims` binds fine — `MtkMmTelFeature` created, `enableIms` called
- BUT `isImsCapabilityAvailable capability=1 regTech=* isAvailable=false`
- **No `NetworkRequest` with `CAPABILITY_IMS` is ever born**
- `RmmDcImsURCHandler` (in mtkfusionrild):
  `handleImsBearerNotification enable=1` → `imsPdnState=0` → `no ongoing ACTIVATED or DEACTIVATED event` … then silence
- The IMS PDN is never activated → `ccmni2` stays DOWN → no IMS registration → no VoLTE
- `com.mediatek.ims` has a thread stuck forever on `Waiting for service 'media.VTS'`
  (vtservice / ViLTE glue mismatch)

Green (NOT the problem): radio on LTE, `mVopsSupport=2` (cell advertises Vops), SIM provisioned,
`carrier_volte_available_bool=true` for SIM1, MTK IMS HALs alive
(`mtkfusionrild` serving `imsAospSlot1/2`), apns in /product present for default data.

## 2. Root causes found

### 2.1 Missing IMS APNs for Iranian carriers
`/product/etc/apns-conf.xml` (built from `vendor/apn/IR.xml`) had **no `type="ims"` APN**
for 43235 / 43211 / 43220. Without an IMS APN the framework can never attempt the IMS PDN.
→ **Fix:** added 3 entries to `vendor/apn/IR.xml`
(Irancell IMS / IR-MCI IMS / Rightel IMS — `apn="ims"`, IPV4V6, `type="ims"`).

### 2.2 Missing `vendor/mediatek/ims` tree + mtk-ims RRO overlays
Working ROMs (xiaomi-mediatek-devs lineage-22.2 → lineage-23.0 for mt6895) ship a dedicated
`vendor/mediatek/ims` tree containing:
- RRO overlays **`mtk-ims`** and **`mtk-ims-telephony`** containing:
  - `config_ims_package = com.mediatek.ims`
  - `config_carrier_volte_available = true`
  - `config_dynamic_bind_ims = true`
  - `config_ims_mmtel_package` / `config_ims_rcs_package`
- IMS product properties (`persist.dbg.vt/wfc_avail_ovr=1`, `persist.vendor.ims_support=1`,
  `persist.vendor.volte_support=1`, `persist.vendor.vilte_support=0`)

This tree was completely absent from our build.

### 2.3 Frankenstein IMS stack (secondary risk — NOT touched yet)
Commit `280ec82` ("Update IMS stack from aristotle OS3.0.1.0.WMFIDXM") replaced the IMS
jars/libs with a remix from another device. Compared to the working tree:
- `mediatek-ims-base.jar` / `mediatek-ims-common.jar` SHAs differ completely
- `libimsma*.so` differ
- `mediatek-framework.jar` and `mediatek-common.jar` are **absent** here but present there
- `ImsService expects mediatek-ims-extension-plugin.jar in system_ext` (per that commit)
If after this build IMS still doesn't activate, swap the whole IMS blob set to the
xiaomi-mediatek-devs versions (or revert 280ec82 + its follow-ups).

## 3. Changes applied in this session

| Repo | File | Change |
|---|---|---|
| (new clone) | `vendor/mediatek/ims/` | cloned from xiaomi-mediatek-devs, branch `android-16`. `ims.mk` trimmed: only RRO overlays + IMS product props (the `ImsService` APK + privapp permissions stay with vendor/xiaomi/mt6895-common to avoid duplicates) |
| device/xiaomi/mt6895-common | `mt6895.mk` | appended at EOF: `$(call inherit-product, vendor/mediatek/ims/ims.mk)` |
| vendor/apn | `IR.xml` | + Irancell IMS (43235), + IR-MCI IMS (43211), + Rightel IMS (43220) — `apn="ims"` IPV4V6 |

Already-correct in the tree (do not "fix" these):
- `product.prop`: `persist.dbg.volte_avail_ovr=1`; `vendor.prop`: `persist.vendor.mtk.volte.enable=1`
- `PRODUCT_BOOT_JARS` keeps  `mediatek-ims-base` + `mediatek-ims-common` (+ camerax-vendor-extensions).
Verified odexable on A17. **Do NOT** add `mediatek-telephony-common` to boot (MtkGsmMmiCode A14-era
bytecode fails dex2oat against A17 telephony).
- The handler chain prints `setVolteSettingStatus value=3` — that's an internal MTK enum, NOT a broken property.

## 4. Post-flash test checklist

```sh
adb connect <phone-ip>:5555
adb shell su -c 'grep type=\"ims\" /product/etc/apns-conf.xml'           # 3 Iranian entries
adb shell su -c 'content query --uri content://telephony/carriers' | grep IrancellIMS
adb shell ip addr show ccmni2                        # should show inet addr once IMS PDN activates
adb shell logcat -d -b radio | grep -E 'RtmIms|RmmDc'                   # expect isImsReg=1
adb shell dumpsys telephony.registry | grep -oE 'mVopsSupport = [0-9]'
# SUCCESS = VoLTE icon + call NOT falling back to CS + ccmni2 UP + no media.VTS loop
```

## 5. Reference material

- https://github.com/xiaomi-mediatek-devs/android_vendor_mediatek_ims (branch `android-16`)
- https://github.com/xiaomi-mediatek-devs/android_vendor_xiaomi_mt6895-common (`lineage-22.2` → `lineage-23.0` lineage history)
- Runtime persist props are stored in /data and survive builds; `persist.vendor.radio.volte_state`
  is written by the RIL at runtime — ignore it, it's not a defect.
- Build: `source build/envsetup.sh && lunch <target>` then `m bacon -j16`
  (this tree's product: `infinity_xaga`; also `lineage_xaga` available)

## 5. BUILD-2 FINDING — media.VTS / vtservice never installed (2026-10-18, A17 4.1 build 18.10)

Evidence on device: com.mediatek.ims (pid 1901) loops forever:
  libbinder.ServiceManagerCppClient: Service media.VTS didn't start. Returning NULL
(~5.5 s cadence). MtkMmTelFeature count = 0 in log. Telephony DB already had
Irancell IMS (43235) + IRMCI_IMS (43211) APNs (fixed by build 1). Modem Vops OK
(2 / 3). ccmni2 still DOWN.

Root cause: vendor/xiaomi/mt6895-common/Android.bp DEFINES vtservice
(system_ext cc_prebuilt), vtservice_aidl (vendor HAL) and the videotelephony
HAL modules — but mt6895-common-vendor.mk has ZERO references, so none of them
ever installed; init.vtservice.rc / init.vtservice_aidl.rc were never copied.
libmtk_vt_service.so sat dangling in system_ext/lib64. ImsService init blocks
on media.VTS -> no MmTel handshake -> no IMS PDN -> no VoLTE.

Fix applied (on kalios mount):
1. mt6895-common-vendor.mk: appended PRODUCT_PACKAGES (vtservice,
   vtservice_aidl, videotelephony-impl / -V1-ndk / -V1-ndk_vendor / @1.0) +
   PRODUCT_COPY_FILES for init.vtservice.rc (system_ext) and
   init.vtservice_aidl.rc (vendor). Deps verified present in Android.bp
   (libmtk_vt_service / wrapper, libvt_avsync, wechat.beanpod, libthhclient,
   libimsg_log).
2. vendor/mediatek/ims/ims.mk: persist.vendor.vilte_support 0 -> 1
   (init.vtservice.rc enables the daemon only when vilte_support=1, which is
   what registers media.VTS).

Rebuild confirmation checklist:
  /system_ext/bin/vtservice, /system_ext/etc/init/init.vtservice.rc,
  /vendor/bin/hw/vtservice_aidl, /vendor/etc/init/init.vtservice_aidl.rc
  must exist in the new out/; then on device: `service list | grep VTS`
  should show media.VTS, and logcat must create MtkMmTelFeature.

## 6. BUILD-3: linker crash of vtservice + AudioTrack shim (FIXED - live-verified)

### Symptom
After shipping the VTS stack, /system_ext/bin/vtservice crash-looped:
    CANNOT LINK EXECUTABLE "/system_ext/bin/vtservice":
    cannot locate symbol "_ZN7android10AudioTrackC1E19audio_stream_type_t...tbfi"
    referenced by "/system_ext/lib64/libsink-mtk.so"

### Root cause
Full-tree symbol audit proved the ENTIRE ViLTE blob stack has exactly ONE missing
symbol: libsink-mtk.so links the legacy 16-arg android::AudioTrack ctor ending
"...audio_attributes_tbfi" (its DT_NEEDED libmedia.so was ~13-era; on Android 17
that ctor moved to libaudioclient.so and gained one trailing param:
const std::string& codecProvenance = "" -> mangled ...bfiRKNSt3__112basic_string...).
All other blob libs (libmtk_vt_*, libimsma*, libvt_avsync, ...) resolve cleanly.

### Fix (applied in-tree + live-tested on device)
1. vendor/xiaomi/mt6895-common/shim/lib/vt_audiotrack_shim.c : pure-C shim that
   exports the legacy mangled ctor and forwards to the A17 ctor with an empty
   libc++ SSO std::string (layout {char* data; size_t size; char buf[16]}).
2. shim/Android.bp: cc_library_shared "libvt_audiotrack_shim", stl: "none",
   shared_libs: ["libaudioclient"], system_ext_specific.
3. patchelf --add-needed libvt_audiotrack_shim.so on
   proprietary/system_ext/lib64/libsink-mtk.so (original kept as .so.bak).
4. PRODUCT_PACKAGES += libvt_audiotrack_shim in mt6895-common-vendor.mk.

### Live verification (no rebuild needed)
/system_ext is remountable rw; copied shim + patched libsink-mtk.so live into
/system_ext/lib64 (chcon u:object_r:system_lib_file:s0), restarted service:
    init.svc.vtservice = running
    service list: "media.VTS: [android.hardware.IVTService]"  REGISTERED
and the "Service media.VTS didn't start" loop in com.mediatek.ims ended -> VoLTE up.

### Dual-slot VoLTE
IMS props (ims.mk: persist.vendor.volte_support=1 / persist.vendor.vilte_support=1)
are GLOBAL - MTK applies them per slot at the telephony layer; IMS APNs present
for both carriers (Irancell 43235 / IRMCI 43211); vtservice/media.VTS serves both
subscriptions. Runtime per-slot check:
    dumpsys telephony.registry | grep -iA3 ims
and MmTelFeature creation lines for phone0/phone1 in logcat. Nothing in the shipped
fix is slot-specific, so both slots inherit the same enable path as the reference
ROMs where dual-slot VoLTE worked.

## 7. EngineerMode "IMS test" toggle crash + worldwide carrier-config question

### Crash (found & fixed)
Toggling IMS test in com.mediatek.engineermode killed the app:
    NPE "println needs a message" (Elog.e masking the real failure)
    <- EmUtils.getEmHidlService (getService failed)
    <- EmHalService.setImsTestMode <- ImsActivity handler
Real chain underneath:
1. em_hidl HAL (vendor.mediatek.hardware.engineermode@1.x::IEmd/EmHidlServer)
   segfaults at startup: vendor::mediatek...V1_3::implementation::cpp_main()+124
   does RefBase::incStrong on an object whose RefBase subobject is at +0x60
   (ctor calls RefBaseC2(this+0x60)) while cpp_main computes the adjusted
   pointer via the PRIMARY vtable offset_to_top (=0). Call never matches -> NULL
   mRefs -> SIGSEGV @0x4. Blob-internal A17-vs-MIUI-runtime mismatch.
2. Even when that is patched, registration is rejected:
   "Cannot find entry vendor.mediatek.hardware.engineermode@1.3::IEmd/EmHidlServer
   in either framework or device VINTF manifest" - vendor manifest fragment was
   LOST during blob extraction (stock MIUI shipped it).
3. Fix applied (in-tree + live on device):
   a. proprietary/vendor/bin/em_hidl: NOP'd the single `bl RefBase::incStrong`
      at 0x70e8 (bj 0x16170094 -> NOP 1f2003d5). Pristine blob kept as
      em_hidl.bak. The registerAsService happens earlier in cpp_main, so the
      refcount pass is only for a temporary sp<> and can be dropped safely.
   b. proprietary/vendor/etc/vintf/manifest/manifest_em_hidl.xml: new VINTF
      fragment (hal vendor.mediatek.hardware.engineermode, transport hwbinder,
      version 1.0-1.3, fqnames IEmd/EmHidlServer x4).
   c. shim/Android.bp: prebuilt_etc_xml "manifest_em_hidl.xml" (identical
      template to neighboring fragments).
   d. mt6895-common-vendor.mk: manifest_em_hidl.xml added to PREBUILT list.
   On device: /vendor/bin/em_hidl context = u:object_r:em_hidl_exec:s0
   (stock per vendor_file_contexts; hal_engineermode_exec was wrong).

### Carrier config "only slot 1 true" (worldwide question)
dumpsys carrier_config shows carrier_volte_available_bool=true only for the
carrier whose entry in the AOSP carrier DB enables it (here HaMCI 432-11 ->
carrierId 1967 = true; Irancell 432-35 -> carrierId 1987 = false). The actual
VoLTE/VT/WFC gating does NOT use that raw value: frameworks/opt/net/ims
ImsManager reads the dbg overrides (persist.dbg.volte_avail_ovr=1,
persist.dbg.vt_avail_ovr=1, persist.dbg.wfc_avail_ovr=1, set globally in
vendor/mediatek/ims/ims.mk) and returns platform-available=true for EVERY
carrier/slot (per-phone override prop persist.dbg.volte_avail_ovr<phoneId>
also supported). Code path has no build-type check in this tree, so it works on
user builds too. => carrier config display difference is cosmetic; IMS/VoLTE is
worldwide-enabled for both slots. No change needed.

## 8. Maintenance pack: MTK_IMS_FIXES/ (re-apply after every source update)

Everything in this chronicle is packaged so a `repo sync` / re-extract / git
reset never re-breaks IMS/VoLTE/EngineerMode:

    ~/infinity/MTK_IMS_FIXES/apply_fixes.sh      # idempotent re-application (7 fixes)
    ~/infinity/MTK_IMS_FIXES/verify_fixes.sh     # PASS/FAIL verification (18 checks)
    ~/infinity/MTK_IMS_FIXES/snippets/           # canonical file contents (shim c/bp,
                                                 #   VINTF fragment, mk/ims.mk blocks)

After applying, validate the two custom modules, then build:

    m libvt_audiotrack_shim manifest_em_hidl.xml   # must pass
    m bacon

Raw vendor files modified (pristine copies kept as .bak):
  - proprietary/system_ext/lib64/libsink-mtk.so  (DT_NEEDED + libvt_audiotrack_shim.so)
  - proprietary/vendor/bin/em_hidl               (NOP @0x70e8, kills V1_3 cpp_main segfault)
New tree paths (created by the script from snippets):
  - vendor/xiaomi/mt6895-common/shim/{Android.bp, lib/vt_audiotrack_shim.c}
  - vendor/xiaomi/mt6895-common/emhal/{Android.bp, manifest_em_hidl.xml}
Make wiring: mt6895-common-vendor.mk tail (VTS packages + rc copy files +
             manifest_em_hidl.xml)  /  ims.mk property overrides.
Duplicate-module: vendor/mediatek/ims/Android.bp loses any android_app_import
             named "ImsService" (xiaomi prebuilt wins).
             (Soong only scans dirs whose build file is literally Android.bp.)

Sandbox-tested end-to-end: fresh-tree apply path 7/7 PASS; idempotent second
run all SKIP; dedupe removes real + synthetic dup blocks. See README.md for
the full map and the "new blobs arrived" procedure (§7 / §6 references).

## 9. EngineerMode CMW500 (Registration mode) — semantics + recovery

**Function chain (live-traced):**
EngineerMode app → `em_hidl::setImsTestMode(data)` → writes
`persist.vendor.radio.imstestmode` (sepolicy: `em_hidl.te` grants exactly
`set_prop`, nothing else) → `libmtk-ril.so` consumes it (AT command family
`AT+EIMSCMODE…` found in `libmtkrilutils.so`) → modem GCF/CMW500 lab mode.

**Key behaviors learned the hard way (all device-verified 2026-10-19):**
1. `libmtk-ril` samples `imstestmode` ONLY at RIL init. Setting/changing the
   prop at runtime produces NO modem reaction whatsoever (watcher absent).
2. Flipping CMW500 ↔ Default inside EngineerMode dead-locks the current radio
   session: toggling back does not re-attach IMS. A **reboot** always fixes it.
3. EM UI writes can silently fail (prop observed staying at old value after a
   "revert to CMW500" click). Guard: read
   `persist.vendor.radio.imstestmode` after every EM change to confirm.
4. `mtkfusionrild` (service name `vendor.ril-daemon-mtk`,
   `/vendor/etc/init/mtkrild.rc`) is a **oneshot** started only via the
   `vold.decrypt=trigger_restart_framework` trigger. Killing it does NOT
   respawn — must `start vendor.ril-daemon-mtk` manually or reboot.
   Practical rule: just reboot, don't touch rild.

**Operating conclusion for this device:** CMW500 mode stays OFF (prop = 0);
VoLTE registers normally on both slots after a clean attach. An earlier
"VoLTE only works with CMW500" impression came from the stuck-radio session
above, not a persistent requirement (stock showed the same behavior).

**Best practice:** set the mode IN EM first (if ever needed), confirm the
prop value changed, then reboot once. Never flip modes twice per session.

## 10. Bundled-engine Chromium browsers (GoLogin etc.) - app_zygote spawn fix

Symptom: in-app Chromium engines (GoLogin/Orbita, Kiwi and similar forks,
browser-capable SDK apps) launch but browsing is dead: logcat shows
"Process ...:sandboxed_process0:...NativeOnlySandboxedProcessService0 failed to
attach" then "start timeout". Chrome/WebView work fine.

Root cause (SELinux): the app-owned child zygote (app package _zygote process,
domain app_zygote) re-opens /system/bin/app_process64 (label zygote_exec)
before its memfd self-exec; read was denied (19x retry loop):
  avc: denied { read } name="app_process64" scontext=u:r:app_zygote
       tcontext=u:object_r:zygote_exec:s0
The memfd EXEC step itself is upstream policy (app_zygote_tmpfs/memfd_file
execute) and neverallow-protected (neverallow app_zygote *:file
execute_no_trans forbids disk-execute; only read/getattr may be granted).
Chrome avoids this entirely (isolated spawn, no child zygote); bundled
engines do not.

Fix (permanent, 8th kit fix):
  device/mediatek/sepolicy_vndr/base/private/app_zygote_browsers.te
  (base/private is wired as SYSTEM_EXT_PRIVATE_SEPOLICY_DIRS = platform-
   private extension from the device tree; canonical MTK carve-out):
    allow app_zygote zygote_exec:file { getattr open read };
    allow app_zygote tombstoned_crash_socket:sock_file write;
Re-applied after every sync by MTK_IMS_FIXES/apply_fixes.sh (FIX 8),
verified by verify_fixes.sh.

Side-find (NOT yet fixed): tombstone_36/35 = vendor.dolby.media.c2@1.0-service
SIGSEGV in BnHwComponentStore::_hidl_createComponent -> RefBase::incStrong on
the returned object - the SAME A17-vs-MTK RefBase layout mismatch family as
the em_hidl bug (see section 7). Breaks codec-based features requesting the
Dolby c2 store (video decode paths in bundled engines are candidates).
Same remedy class as em_hidl if it blocks a feature: find the failing
incStrong/check sequence in the blob and NOP/neutralize it.

## 11. Dolby `vendor.dolby.media.c2@1.0-service` (FIX 9) — 2026-10-19
Symptom: recurring SIGSEGV (tombstone_35/_36) in the Dolby C2 HAL.
Analysis: pc in `/vendor/lib64/android.hardware.media.c2@1.0.so`
(BuildId b0a4582dc4e44b2260b504f06a8050b6), frame
`BnHwComponentStore::_hidl_createComponent` calling `RefBase::incStrong`
on the returned component; fault addr 0x4 = null `mRefs` at the A17
offset. Root cause = the blob service builds component objects against
the pre-A17 RefBase layout; A17 libutils dereferences the new offset and
faults. Disassembly at the call site: null-checked `cbz x8, 5ca3c` then
`bl RefBase::incStrong` @0x5ca30; paired `bl decStrong` @0x5cae0.
Live experiment: pair-NOP patch (both 4-byte `bl` -> `d503201f`) applied
to the device lib -> service restarts clean (pid 30659), registered
`@1.0::IComponentStore/default1`, stable, no new tombstones. Proven root
cause. BUT the interface lib is Soong-built each build (mk entry
`android.hardware.media.c2@1.0.vendor`), so a binary patch cannot persist
tree-side. Decision: disable the service — FIX 9 drops the c2 VINTF
fragment + rc copy + PACKAGES entry from `hardware/dolby/dolby.mk`
(marker banner `MTK_IMS_FIXES FIX 9`). Dolby AUDIO untouched: dms HAL,
dax-default, LunarisDolby app. Loss: `c2.dolby.*` video codecs
(AC-4/AC-3/E-AC-3 decoders) — the only consumers are niche video players.
The original dolby repo survives at `hardware/dolby` (incl. its own
sepolicy/vendor/hal_dms*.te + contexts — do NOT duplicate those).

## 12. Bypass charging made permanent (FIX 10) — 2026-10-19
LineageParts `Extra Battery options` (`org.lineageos.lineageparts`,
platform-signed => `system_app` domain) writes
`/sys/class/power_supply/usb/bypass_charging` directly (FileWriter;
writer path confirmed in ExtraBatteryOptions.java). DAC: ueventd
`0660 system system` (ueventd.mt6895.rc:156). SELinux: `system_app.te`
in `device/xiaomi/mt6895-common/sepolicy/vendor/` grants
`sysfs_power_supply:file rw_file_perms` + dir search (label from
`genfscon sysfs /devices/.../power_supply u:object_r:sysfs_power_supply:s0`).
Both tree files already existed but were UNCOMMITTED and would vanish on
`repo sync` — FIX 10 re-applies them idempotently (append-if-missing) and
verify_fixes.sh now asserts both. Live device already shows the node
working (user-applied temp fix); after the final flash the tree pieces
make it permanent. Kernel-side naming confirmed: `bypass_charging`
(lowercase, correct spelling — the earlier `bypass_chrging` grep was a
typo and did indeed find nothing).

## 13. App-zygote seccomp SIGSYS 149 — browser flapping (FIX 11) — 2026-10-19
Symptom: browsers (Brave/Chrome) flapped: app-zygote children died moments
after every launch (`>>> com.brave.browser_zygote <<<`, `Cause: seccomp
prevented call to disallowed arm64 system call 149`, denied setresgid args
0x15F93..F99 = 90003..90009). Gid=90003.. is INSIDE the app-zygote isolated
space, so the denial meant the installed filter was NARROWER than the UIDs
actually handed out: the stock else-branch of
`ProcessList.createAppZygoteForProcessIfNeeded()` takes a per-app slice
(`mAppIsolatedUidRangeAllocator.getIsolatedUidRangeLocked(...)`) for the
zygote's own `--uid-range-start/end`, while child UIDs are allocated by the
wrapper `getOrCreateIsolatedUidRangeLocked()`; a force-stop frees and
re-allocates the slice between the two moments -> filter range no longer
covers the child's uid -> bionic `install_setuidgid_seccomp_filter` BPF
kills setresgid (arm64 syscall 149) in SpecializeCommon. First cold launch
worked (consistent slice) — that is why GoLogin "worked" while restarted
Brave/Chrome crashed.

Fix (frameworks/base only,
`frameworks/base/services/core/java/com/android/server/am/ProcessList.java`):
the else-branch now grants the full app-zygote isolated space —
`firstUid = Process.FIRST_APP_ZYGOTE_ISOLATED_UID;`
`lastUid  = Process.LAST_APP_ZYGOTE_ISOLATED_UID;` — so the child-UID
allocator cannot race outside the filter anymore. The safesetid-enabled
upstream branch (`use_safesetid_uid_policy2`) already grants the same global
space, so the trade-off (zygote may gid-shift across 90000-98999) matches
an existing sanctioned configuration; SELinux was NOT involved (0 AVCs).

Debug dead-ends documented for future me: the constants are javac-inlined
(`ldc_w 90000/98999`), so dex string greps/field-name greps CANNOT detect
the change — use `javap -c -p` on
`out/soong/.intermediates/frameworks/base/services/core/
services.core.unboosted/android_common/jarjar/services.core.unboosted.jar`
class `com/android/server/am/ProcessList` and look after the
`disallowAllUidTransitionsFrom` call; verify the FLASHED jar, not the
staged `out/` copy (device ran md5 3d0b8114…, out/ had c156c6… — three
"fix-contains" conclusions were wrong until the on-device jar was dumped;
jar outputs are deterministic so equal md5 == equal code, and the else
branch's `getIsolatedUidRangeLocked` javap hit belongs to the unrelated
`removeProcessFromAppZygoteLocked` cleanup path, not the filter branch).

Validation (19.10.2026, flashed FIX-11 build, no root): 3 cycles of
force-stop + relaunch for Brave/Chrome/GoLogin via adb -> app zygotes and
their `sandboxed_process0` children alive (u0_i23/24/26), crash buffer
seccomp count = 0. Old flashed build under the identical stress: 12 kills.
Kit steps: apply_fixes.sh [11/11] + verify_fixes.sh FIX 11 checks.

## 14. FIX 12+13 — SELinux regressions from the A17 source update (2026-10-21)

**Symptom A:** MiuiCamera (com.android.camera) SIGSEGV in thread `CameraSetup`,
addr 0x18, ONLY when switching AWAY from Night mode to any other mode. Every
other mode combination fine. Also: user reports other (unnamed) app bug fixed.
**Symptom B:** since the same flash, /data/tombstones stopped receiving new
entries at all; every app native crash printed only
  crash_dump failed to dump process <pid>: Failed to initialize unwinder
  object: Failed to parse maps
(system_domain dumps still worked, camera crashes were invisible).

Diagnosis = SELinux, proven by setenforce 0 making BOTH problems vanish:
- A17 policy refresh dropped the platform-app → MTK camera HAL grants.
  MiuiCamera binds `mtk_hal_camera` DIRECTLY (HIDL ops for mode switch /
  multiframe plumbing); a denied `binder { call transfer }` returns NULL on
  the CameraSetup path -> unguarded deref -> SIGSEGV @0x18. Permissive AVC
  capture (16:18):
    { call } platform_app_36 -> mtk_hal_camera (RequestDispatch)
    { transfer } platform_app_36 <-> mtk_hal_camera
    { getattr } platform_app_36 -> unlabeled filesystem (dmabuf mount "/")
- App processes (any app_uid, tested systemui/launcher/camera) map an MTK
  device-only memfd named `/memfd:mf:/proc/<pid>/smaps (deleted)` labeled
  tmpfs. crash_dump's libunwindstack opens every mapped file to read ELF
  build-ids; { read getattr } denied -> parse_maps aborts -> no tombstone,
  no backtrace. system_server lacks that mapping, hence "system dumps OK".
  Second needed grant: crash_dump reads cgroup2 cgroup.procs of sibling
  threads (`/sys/fs/cgroup/apps/uid_*/pid_*/cgroup.procs`, type cgroup_v2).

**Tree fixes (both in MTK_IMS_FIXES kit):**
- FIX 12: device/xiaomi/mt6895-common/sepolicy/vendor/miuicamera_hal_binder.te
  platform_app(_36) <-> mtk_hal_camera binder call/transfer, unlabeled:fs getattr.
- FIX 13: device/mediatek/sepolicy_vndr/base/private/crash_dump_mtk_memfd.te
  crash_dump tmpfs:file read/getattr/open + cgroup_v2:file read/getattr/open.
Both registered in apply_fixes.sh (idempotent) + verify_fixes.sh.
Live hot-patch via `ksud sepolicy patch` FAILED (Tool's Rust parser chokes on
the statement syntax) — do NOT rely on that path; tree build is the fix.
Reverted experimental state: device remains permissive until this build is
flashed (rebuild ships a correct policy; flashing restores Enforcing DNA).

## 15. FIX 14+15 + crash_dump write — the REAL MiuiCamera crash (2026-10-21, post-flash)

After the 4.1-21.10 build was flashed the camera still crashed. Deeper analysis
(with working tombstones, see below) found the true chain:

**FIX 12 was correct but not sufficient** — after it, the `platform_app_36 ->
mtk_hal_camera` binder denials were gone (verified live). What remained was ONE
app-side denial, repeated 3x per camera start:

    avc: denied { find } for interface=vendor.xiaomi.hardware.campostproc::IMiPostProcService
         scontext=u:r:platform_app_36 tcontext=u:object_r:default_android_hwservice
         tclass=hwservice_manager

Why it is fatal: the interface has **no hwservice_contexts entry**, so the
hwservicemanager falls back to the catch-all type `default_android_hwservice`,
which A17 marks protected:

    system/sepolicy/public/hwservice.te:
      type default_android_hwservice, hwservice_manager_type, protected_hwservice;
    system/sepolicy/private/domain.te:
      neverallow * default_android_hwservice:hwservice_manager *;

So the lookup is denied -> MiuiCamera never gets a post-processing service
handle -> its super-night session is torn down before the plugin was ever
initialised -> the Arcsoft plugin destroys an uninitialised engine:

    #00 /vendor/lib64/libArcNetMtk.so (mcSuperNetMTK_NPURelease+24)
    #01 /vendor/lib64/libarcsoft_super_night_raw.so (ARC_SN_PostProcess+676)
    #04 /vendor/lib64/com.xiaomi.plugin.rawsuperlight.so (ArcsoftRawSuperlight::uninit+32)
    #06 /vendor/lib64/libmialgoengine2.so (mialgo2::MiaOfflinePostProcSession::flush)
    #11 /vendor/lib64/libmialgoengine.so (mialgo::MiPostProcServiceIntf::destroySession)
    #13 MIADestroySession (JNI) <- com.xiaomi.engine.TaskSession.destroy
    -> signal 11, fault addr 0x18, thread CameraSetup, com.android.camera

**FIX 14** = give the service a real, non-protected type + context + client
find (same shape as hal_mlipay_hwservice / hal_mtdservice_hwservice in this
tree, and the same shape upstream uses on spes):
  device/xiaomi/mt6895-common/sepolicy/vendor/hal_camerapostproc.te (new)
  device/xiaomi/mt6895-common/sepolicy/vendor/hwservice_contexts (+1 line)
With the lookup allowed, the client behaves exactly like on a permissive
device (verified live on-device: camera stays up, no tombstone).

**FIX 15** = the MTK camera HAL was denied { open } on
/dev/__properties__/u:object_r:default_prop:s0 (legacy property API) -> it
silently ran with default configuration. Same for hal_audio_default.
  device/xiaomi/mt6895-common/sepolicy/vendor/mtk_hal_camera.te (+2 lines)

**FIX 13b** = crash_dump needs `write` (not just read) on the MTK memfd: the
unwinder opens /proc/<pid>/map_files/<start>-<end> with write access, so
without it the map table is dropped entirely ("No memory maps found", no
symbols). Verified live: with the write grant the tombstone has 4212 map
entries and full symbolised frames.

### Live-test recipe (no rebuild needed) — KernelSU runtime policy
`ksud sepolicy patch` takes ONE statement/perm per call (more are parsed but
only the first is applied). Syntax is space separated, no colons:
    su -c 'ksud sepolicy patch "allow platform_app_36 hal_cas_hwservice hwservice_manager find"'
To test a NEW hwservice type live: give the interface a temporary, existing
non-protected type in /vendor/etc/selinux/vendor_hwservice_contexts
(remount /vendor rw), restart hwservicemanager (ctl.restart hwservicemanager)
and grant `find` on that type. NOTE: restarting hwservicemanager makes
/vendor/bin/mtd_isee abort ("Could not register IMTService") until reboot.
