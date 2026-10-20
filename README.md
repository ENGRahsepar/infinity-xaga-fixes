# MTK IMS / VoLTE / EngineerMode fixes — xaga (Poco X4 GT, MT6895)

**Infinity X A17 — self-build maintenance pack — reapply after every source update.**

Everything needed to restore IMS/VoLTE (and EngineerMode) on ANY carrier, BOTH SIM
slots, every re-sync of the tree. Two scripts do all of it:

```bash
MTK_IMS_FIXES/apply_fixes.sh        # idempotent re-application (DRYRUN=1 to preview)
MTK_IMS_FIXES/verify_fixes.sh       # check-only PASS/FAIL pass
DRYRUN=1 MTK_IMS_FIXES/apply_fixes.sh   # safe preview
```

`apply_fixes.sh` is the ONLY thing you need to rerun after a `repo sync` /
re-extract / git reset. Then validate and build:

```bash
m libvt_audiotrack_shim manifest_em_hidl.xml   # must pass (few minutes, cached)
m bacon
```

---

## The fixes (what & why)

### FIX 1-2 — vtservice stack (root cause of VoLTE being dead on ALL A17 builds)
VoLTE died at commit `3c29f00` ("Infinity X 4.0-BETA ... vtservice stack dropped
(ViLTE), vt libs kept for ImsService") — the VTS daemon was no longer installed,
so `com.mediatek.ims` blocked forever on `Service media.VTS didn't start` and no
MtkMmTelFeature ever existed.

1. **Company blob + linker (BUILD-3 finding)** — `libsink-mtk.so` (xaga V816.0.14.0
   ULQMIXM extract) needs the legacy 16-arg `android::AudioTrack` ctor; Android 17
   moved it to `libaudioclient.so` and added one trailing
   `const std::string& codecProvenance` parameter. Deployments ship a new
   pure-C shim module `libvt_audiotrack_shim` (one exported symbol, forwards to
   the A17 ctor with an empty SSO string) plus `patchelf --add-needed
   libvt_audiotrack_shim.so` onto the blob (pristine kept as `.so.bak`).
2. **Emp route** — whole-tree dynsym audit proved exactly ONE missing symbol
   across the entire ViLTE blob set (`libsink-mtk.so`, everything else clean).

3. **HAL startup** — `em_hidl` (EngineerMode HAL
   `vendor.mediatek.hardware.engineermode@1.x::IEmd/EmHidlServer`):
   `cpp_main()` at `%0x70e8` calls `RefBase::incStrong` on an object whose
   RefBase subobject is at `+0x60` (A17-vs-MIUI layout mismatch) — segfault.
   Fixed by NOP'ing that single call (registration happens earlier in
   `cpp_main`, so the temp `sp<>` refcount pass can be dropped). Pristine
   blob kept as `em_hidl.bak`.
4. **VINTF manifest fragment** — the stock entry for
   `vendor.mediatek.hardware.engineermode` was lost in extraction, without which
   hwservicemanager rejects the HAL and the EngineerMode "IMS test" toggle
   crashes the app (NPE in `Elog.e` masking the real failure). New fragment:
   `emhal/manifest_em_hidl.xml` + `prebuilt_etc_xml` module in
   `emhal/Android.bp` (Soong only scans dirs whose build file is literally
   named `Android.bp` — do NOT rename).
5. **Install wiring** — `mt6895-common-vendor.mk` never had the VTS modules in
   any list (they were defined but never installed). The appended block installs
   vtservice, vtservice_aidl, videotelephony HALs, the shim, and the two
   `init.vtservice*.rc` files.

### FIX 3 — IMS availability per carrier (WORLDWIDE, both slots)
AOSP carrier DB lacks `carrier_volte_available_bool=true` for many carriers
(Irancell 432-35 false, MCI 432-11 true — the "only slot 1 true" observation is
cosmetic). The REAL gate is `ImsManager` (frameworks/opt/net/ims) dbg overrides,
which support per-phone props and honor the plain global prop on user builds too:

```
persist.dbg.volte_avail_ovr=1     persist.dbg.vt_avail_ovr=1
persist.dbg.wfc_avail_ovr=1       persist.vendor.vilte_support=1
persist.vendor.ims_support=1      persist.vendor.volte_support=1
```
Set globally in `vendor/mediatek/ims/ims.mk` — every carrier, both SIM slots.

### FIX 4 — duplicate ImsService module
`vendor/mediatek/ims/Android.bp` shipped its own `android_app_import` named
`ImsService`, clashing with xiaomi's `system_ext/priv-app/ImsService.apk`
prebuilt (Soong assertion). The dup is removed; xiaomi's APK is the installed
one. Re-applier removes any reappearing block in that ONE file only.

### Not touched here
- Kernel (ESK-Reborn): see `DEVELOPMENT.md` + kernel repo branches
  `akali/17.0` / `akali/16.2-rebase`.
- Root (ReSukiSU / SuSFS) — by design not in kernel; separate AnyKernel3 flash.

---

## File map

| Path | Purpose |
| ---- | ------- |
| `MTK_IMS_FIXES/apply_fixes.sh` | idempotent re-application |
| `MTK_IMS_FIXES/verify_fixes.sh` | PASS/FAIL check (also live device when adb on) |
| `MTK_IMS_FIXES/snippets/*` | canonical file contents to restore |
| `vendor/xiaomi/mt6895-common/shim/` | `libvt_audiotrack_shim` (C shim) |
| `vendor/xiaomi/mt6895-common/emhal/` | EngineerMode VINTF manifest fragment + module |
| `vendor/xiaomi/mt6895-common/proprietary/system_ext/lib64/libsink-mtk.so(.bak)` | patched blob |
| `vendor/xiaomi/mt6895-common/proprietary/vendor/bin/em_hidl(.bak)` | patched blob |
| `vendor/xiaomi/mt6895-common/mt6895-common-vendor.mk` | install wiring (tail of file) |
| `vendor/mediatek/ims/ims.mk` | dbg IMS props + vilte=1 |
| `vendor/mediatek/ims/Android.bp` | ImsService dup removed |
| `frameworks/base/services/core/java/com/android/server/am/ProcessList.java` | app-zygote seccomp full-range grant (FIX 11; backup `.pre_fix11`) |
| `IMS_FIX_NOTES.md` | full debugging chronicle (§1-§7) |

## Flash-day verification (already validated live once)

```bash
adb -s 100.67.8.82:5555 shell "su -c 'getprop init.svc.vtservice; getprop init.svc.emhidl_user'"
adb -s 100.67.8.82:5555 shell service list | grep -E "media.VTS"
dumpsys telephony.registry | grep -iA3 ims       # expect MmTel per phone0/phone1
# EngineerMode -> IMS test toggle: no crash
```

## Bundled-engine Chromium browsers (GoLogin/Orbita, Kiwi forks, etc.)
FIX 8 (app_zygote_browsers.te in `device/mediatek/sepolicy_vndr/base/private/`,
installed via apply_fixes.sh) restores the app-owned child-zygote spawn path for
ANY app bundling a Chromium engine. Root cause seen as `sandboxed_process0
failed to attach` / `start timeout` in logcat plus repeated
`avc denied { read } name="app_process64"` in the `app_zygote` domain.
Neverallow-safe (read-only grants; the memfd exec itself is upstream policy).
Chrome needs none of this (plain isolated spawn) - bundled engines do.

Side-find while diagnosing: `vendor.dolby.media.c2@1.0-service` crashes the
same way em_hidl did (null RefBase in `BnHwComponentStore::_hidl_createComponent`,
A17 libutils layout mismatch). Not yet fixed - watch tombstones; video decode
oddities in bundled engines may trace to it.

## If an update pulls NEW blobs
- `libsink-mtk.so` symbol check stays valid (audit script in notes §6).
- `em_hidl`: apply_fixes FAILs loudly if bytes at `0x70e8` differ — then
  re-derive the offset (disassemble `cpp_main`, find the
  `bl RefBase::incStrong` immediately before `joinRpcThreadpool`).
- EngineerMode HAL interface versions may change → update the fragment
  `emhal/manifest_em_hidl.xml` version/fqname list to whatever the newer
  `em_hidl_user.rc` declares.

## Dolby c2 HAL (FIX 9)
`vendor.dolby.media.c2@1.0-service` (the *video* codec store) SIGSEGVs in
`BnHwComponentStore::_hidl_createComponent` -> `RefBase::incStrong` on the
returned component (fault addr 0x4, pc in `android.hardware.media.c2@1.0.so`
BuildId b0a4582...). Same A17-libutils-vs-blob RefBase layout mismatch family
as the em_hidl bug: the blob service hands back component objects built with
the old ABI and A17 libutils reads a stale `mRefs` offset (null). The
interface lib is **Soong-built every build**, so a tree-side binary patch
cannot persist. Resolution chosen: disable the service (drop its VINTF
fragment, rc copy and PACKAGES entry in `hardware/dolby/dolby.mk`). The
**Dolby audio stack is untouched** (dms HAL, dax-default.xml, LunarisDolby
app keep working); only the `c2.dolby.*` video codecs disappear. A live
pair-NOP patch (incStrong @0x5ca30 + paired decStrong @0x5cae0, guarded
null-checks) was validated on-device as the fallback if the service is ever
wanted back: patch the blob lib and keep it as a prebuilt override.

## Bypass charging (FIX 10)
LineageParts `Extra Battery options` writes
`/sys/class/power_supply/usb/bypass_charging` directly from the `system_app`
domain (platform-signed app). Permanent tree pieces, both re-applied by
apply_fixes.sh after every sync:
- `device/xiaomi/mt6895-common/sepolicy/vendor/system_app.te` —
  `allow system_app sysfs_power_supply:file rw_file_perms;` (+dir search,
  batteryinfo parent dir).
- `device/xiaomi/mt6895-common/init/ueventd.mt6895.rc` —
  `/sys/class/power_supply/usb bypass_charging 0660 system system`.

## App-zygote seccomp UID range (FIX 11)
Chromium browsers (Brave, Chrome, GoLogin/Orbita, …) run their sandboxed
renders under an **app zygote**. That zygote installs a bionic seccomp filter
(`ChildZygoteInit` -> `install_setuidgid_seccomp_filter(min, max)`) built from
the `--uid-range-start/end` args ProcessList passes at spawn time. Stock A17
hands it a **per-app slice** of the isolated space; after a force-stop +
relaunch the slice can be freed / re-allocated before the filter is rebuilt,
so the filter no longer covers the UIDs being handed to its own children —
every `setresgid(getuid())` in `SpecializeCommon` then dies with
`Cause: seccomp prevented call to disallowed arm64 system call 149`
(SIGSYS) and the browser flaps. First cold launch usually works (GoLogin
symptom: "GoLogin works, others don't").

Fix: `createAppZygoteForProcessIfNeeded()` else-branch now grants the **whole
app-zygote isolated space** (`Process.FIRST/LAST_APP_ZYGOTE_ISOLATED_UID`,
90000-98999 for user 0) instead of a per-app slice, so no allocation race can
ever produce an out-of-range UID. Trade-off: the app zygote may gid-shift
across the whole space — same privilege shape the upstream safesetid-enabled
path (`use_safesetid_uid_policy2`) already grants, and strictly better than
crashed renderers. Live-validated 19.10.2026: 3 force-stop/relaunch cycles of
Brave + Chrome + GoLogin -> 0 seccomp kills (stock code: 12 kills, browser
zygotes flapping). Tree edit: `frameworks/base/services/core/java/com/android/
server/am/ProcessList.java`, re-applied by apply_fixes.sh (step 11).
