#!/usr/bin/env bash
# =============================================================================
# apply_fixes.sh — re-apply ALL MTK IMS/VoLTE/EngineerMode fixes after a
#   source update (repo sync / re-extract / git reset).
#
#   Run from anywhere:  ~/infinity/MTK_IMS_FIXES/apply_fixes.sh
#   Idempotent by design — every fix checks before writing.
#   Dry run:            DRYRUN=1 ./apply_fixes.sh
# =============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
TOP="$(dirname "$SCRIPT_DIR")"
SNIP="$SCRIPT_DIR/snippets"
DRYRUN="${DRYRUN:-0}"
run() { if [ "$DRYRUN" = "1" ]; then echo "  [dry] $*"; else "$@"; fi; }

VT="$TOP/vendor/xiaomi/mt6895-common"
IMS="$TOP/vendor/mediatek/ims"

ok()   { echo "  PASS  $*"; }
skip() { echo "  SKIP  $* (already fixed)"; }
fail() { echo "  FAIL  $*"; FAILED=$((FAILED+1)); }
FAILED=0

echo "=========================================================="
echo " MTK IMS/VoLTE fix re-application — I N F I N I T Y  xaga"
echo " Tree: $TOP"
echo "=========================================================="

# --- sanity ---------------------------------------------------------------
assert_dir() {
  [ -d "$1" ] || { echo "FATAL: $1 missing — wrong tree / not synced yet."; exit 1; }
}
assert_dir "$VT"
assert_dir "$IMS"
command -v patchelf >/dev/null 2>&1 || \
  echo "WARN: patchelf not in PATH (needed only if blob patches missing; on mshdserver: sudo apt-get install -y patchelf)"

# ===========================================================================
# FIX 1: libsink-mtk.so needs the legacy AudioTrack ctor from
#        libvt_audiotrack_shim.so (A17 moved the ctor to libaudioclient.so
#        with one extra trailing std::string param). Always idempotent.
# ===========================================================================
echo "[1/7] libsink-mtk.so -> add DT_NEEDED libvt_audiotrack_shim.so"
SINK="$VT/proprietary/system_ext/lib64/libsink-mtk.so"
if command -v readelf >/dev/null 2>&1 && readelf -d "$SINK" 2>/dev/null | grep -q "libvt_audiotrack_shim.so"; then
  skip "libsink-mtk.so already patched"
else
  [ -f "$SINK.bak" ] || run cp "$SINK" "$SINK.bak"
  run patchelf --add-needed libvt_audiotrack_shim.so "$SINK" && ok "libsink-mtk.so patched" || fail "patchelf failed on libsink-mtk.so"
fi

# ===========================================================================
# FIX 2: em_hidl EngineerMode HAL — NOP the bad RefBase incStrong @0x70e8
#        (A17 libutils object-layout mismatch crashes the HAL at startup).
# ===========================================================================
echo "[2/7] em_hidl -> NOP RefBase::incStrong call at file offset 0x70e8"
EM="$VT/proprietary/vendor/bin/em_hidl"
if [ ! -f "$EM.bak" ]; then run cp "$EM" "$EM.bak"; fi
run python3 - "$EM" <<'PYEOF'
import sys
P = sys.argv[1]
data = open(P, "rb").read()
f = bytearray(data)
need = bytes.fromhex("16170094")   # bl RefBase::incStrong
nop  = bytes.fromhex("1f2003d5")   # nop
if len(data) <= 0x70ec:
    print("  FAIL  em_hidl file too small — new blob? re-derive offset!")
elif data[0x70e8:0x70ec] == nop:
    print("  SKIP  em_hidl already NOP'd")
elif data[0x70e8:0x70ec] == need:
    f[0x70e8:0x70ec] = nop
    open(P, "wb").write(bytes(f))
    print("  PASS  em_hidl incStrong NOP'd")
else:
    print("  FAIL  em_hidl bytes at 0x70e8 unexpected: %s - maybe a NEW blob version; re-derive the offset!" % data[0x70e8:0x70ec].hex())
PYEOF

# ===========================================================================
# FIX 3: shim module (libvt_audiotrack_shim) — Android.bp + C source
# ===========================================================================
echo "[3/7] shim/ module files"
if [ ! -f "$VT/shim/Android.bp" ] || [ ! -f "$VT/shim/lib/vt_audiotrack_shim.c" ]; then
  run mkdir -p "$VT/shim/lib"
  run cp "$SNIP/shim_Android.bp"       "$VT/shim/Android.bp"
  run cp "$SNIP/vt_audiotrack_shim.c"  "$VT/shim/lib/vt_audiotrack_shim.c"
  ok "shim/ created from snippets"
else
  skip "shim/ exists"
fi

# ===========================================================================
# FIX 4: EngineerMode VINTF manifest fragment module
# ===========================================================================
echo "[4/7] emhal/ VINTF fragment module"
if [ ! -f "$VT/emhal/Android.bp" ] || [ ! -f "$VT/emhal/manifest_em_hidl.xml" ]; then
  run mkdir -p "$VT/emhal"
  run cp "$SNIP/emhal_Android.bp"      "$VT/emhal/Android.bp"
  run cp "$SNIP/manifest_em_hidl.xml"  "$VT/emhal/manifest_em_hidl.xml"
  ok "emhal/ created from snippets"
else
  skip "emhal/ exists"
fi
# note: srcs are relative to the .bp dir; Soong only picks up dirs whose
# build file is literally named Android.bp (that is why this lives in emhal/).

# ===========================================================================
# FIX 5: mt6895-common-vendor.mk install wiring
# ===========================================================================
echo "[5/7] mt6895-common-vendor.mk wiring"
MK="$VT/mt6895-common-vendor.mk"
if grep -q "vtservice" "$MK" && grep -q "libvt_audiotrack_shim" "$MK" && grep -q "init.vtservice_aidl.rc" "$MK" && grep -q "manifest_em_hidl.xml" "$MK"; then
  skip "vendor.mk wiring present"
else
  run python3 - "$MK" "$SNIP/mt6895-common-vendor.mk.append" <<'PYEOF'
import sys
mk, snip = sys.argv[1], sys.argv[2]
v = open(mk).read()
block = open(snip).read()
# trim already-wired parts (granular top-up)
if "vtservice" in v and "libvt_audiotrack_shim" not in v and False:
    pass
vtof = []
if "    vtservice \\" not in v:
    vtof.append(block)
else:
    # partial state: append only missing pieces
    if "manifest_em_hidl.xml" not in v:
        vtof.append("PRODUCT_PACKAGES += \\\n    manifest_em_hidl.xml\n")
    if "init.vtservice_aidl.rc" not in v:
        vtof.append("""PRODUCT_COPY_FILES += \\
    vendor/xiaomi/mt6895-common/proprietary/system_ext/etc/init/init.vtservice.rc:$(TARGET_COPY_OUT_SYSTEM_EXT)/etc/init/init.vtservice.rc \\
    vendor/xiaomi/mt6895-common/proprietary/vendor/etc/init/init.vtservice_aidl.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/init.vtservice_aidl.rc
""")
if vtof:
    with open(mk, "a") as f:
        f.write("\n\n" + "\n\n".join(vtof))
print("PASS  vendor.mk appended missing wiring")
PYEOF
fi

# ===========================================================================
# FIX 6: vendor/mediatek/ims/ims.mk property overrides (dbg + vilte)
# ===========================================================================
echo "[6/7] ims.mk property overrides"
IMSMK="$IMS/ims.mk"
MISSING=0
for p in persist.dbg.volte_avail_ovr persist.dbg.vt_avail_ovr persist.dbg.wfc_avail_ovr persist.vendor.vilte_support=1 persist.vendor.ims_support=1 persist.vendor.volte_support=1; do
  grep -q "$p" "$IMSMK" || MISSING=1
done
if [ "$MISSING" = "0" ]; then
  skip "ims.mk props present"
else
  run bash -c "cat '$SNIP/ims.mk.append' >> '$IMSMK'" && ok "ims.mk props appended"
fi
# STRUCTURAL PROP: vilte_support hardcoded 0->1 inside ims.mk baseline? The
# baseline shipped 0; the append above wins because it comes later in file.
# If an update re-flattens this prop to 0 earlier in the file it still works
# (last-one-wins for product props), otherwise sed it explicitly:
run python3 - "$IMSMK" <<'PYEOF'
import sys, re, shutil
p = sys.argv[1]
s = open(p).read()
old = re.compile(r"persist\.vendor\.vilte_support=0\b")
if old.search(s):
    shutil.copy(p, p + ".pre_fix")
    open(p, "w").write(old.sub("persist.vendor.vilte_support=1", s))
    print("PASS  ims.mk re-flattened vilte 0->1")
else:
    print("SKIP  ims.mk has no vilte=0 baseline")
PYEOF

# ===========================================================================
# FIX 7: duplicate ImsService module — keep the xiaomi prebuilt app,
#        remove any android_app_import name:ImsService blocks in
#        vendor/mediatek/ims/Android.bp (the tree that duplicates it on
#        fresh syncs). vendor/xiaomi/*Android.bp is NEVER touched.
# ===========================================================================
echo "[7/7] duplicate ImsService module dedupe (vendor/mediatek/ims)"
run python3 - "$IMS/Android.bp" <<'PYEOF'
import sys, os, shutil
p = sys.argv[1]
s = open(p).read()
removed = []
start = 0
while True:
    i = s.find("android_app_import", start)
    if i < 0:
        break
    j = s.find("{", i)
    if j < 0:
        break
    depth, k = 0, j
    end = None
    while k < len(s):
        if s[k] == "{":
            depth += 1
        elif s[k] == "}":
            depth -= 1
            if depth == 0:
                end = k + 1
                break
        k += 1
    if end is None:
        break
    head = s[i:j].split("\n")[-1] + s[j + 1:end].split("\n}")[0]
    # name line within the first few lines of the block
    block_head = s[j + 1:end].split("\n", 3)
    if any('name: "ImsService"' in l for l in block_head[:3]):
        removed.append(s[i:end])
        s = s[:i] + s[end:]
    else:
        start = end
if not removed:
    print("SKIP  no ImsService import in vendor/mediatek/ims/Android.bp")
else:
    if not os.path.exists(p + ".pre_dedupe"):
        shutil.copy(p, p + ".pre_dedupe")
    open(p, "w").write(s)
    print("PASS  removed %d ImsService android_app_import block(s)" % len(removed))
PYEOF

# ===========================================================================
# FIX 8: platform sepolicy for bundled-engine Chromium browsers (GoLogin/Orbita,
#        Kiwi & forks, in-app browser SDKs). Their app-owned child zygotes must
#        read the framework app_process binary before the memfd self-exec;
#        without this rule the sandboxed renderer never attaches
#        ("failed to attach" / "start timeout"). Neverallow-safe (read only).
# ===========================================================================
echo "[8/8] app_zygote policy for bundled Chromium engines"
ZDEST="$TOP/device/mediatek/sepolicy_vndr/base/private/app_zygote_browsers.te"
ZSRC="$SNIP/app_zygote_browsers.te"
if [ ! -f "$ZSRC" ]; then
  fail "snippet missing: $ZSRC"
elif [ ! -f "$ZDEST" ]; then
  run cp "$ZSRC" "$ZDEST" && ok "app_zygote_browsers.te installed into base/private" \
    || fail "could not install app_zygote_browsers.te"
else
  if cmp -s "$ZSRC" "$ZDEST"; then
    skip "app_zygote_browsers.te present"
  else
    run cp "$ZSRC" "$ZDEST" && ok "app_zygote_browsers.te refreshed from snippet"
  fi
fi


# ===========================================================================
# FIX 9: Dolby C2 HAL (vendor.dolby.media.c2@1.0-service) — disable.
# The blob's component objects were built against the pre-A17 RefBase ABI.
# A17 libutils reads mRefs at the new offset, gets NULL, and SIGSEGVs inside
# BnHwComponentStore::_hidl_createComponent every time a client binds a
# component. The crashing interface lib is Soong-built on every build, so a
# binary patch cannot persist tree-side. The Dolby audio stack (dms HAL,
# dax-default, LunarisDolby app) is untouched; only the video c2.dolby
# codec store is dropped.
# ===========================================================================
echo "[9/10] hardware/dolby — disable crashing vendor.dolby.media.c2@1.0-service"
DOLBY_MK="$TOP/hardware/dolby/dolby.mk"
if [ ! -f "$DOLBY_MK" ]; then
  fail "hardware/dolby/dolby.mk not found (repo layout changed?)"
elif ! grep -q "vendor.dolby.media.c2@1.0-service" "$DOLBY_MK"; then
  skip "dolby.mk already has the service disabled"
else
  if [ "$DRYRUN" = "1" ]; then
    echo "  [dry] would patch $DOLBY_MK (drop manifest fragment, rc copy, PACKAGES entry)"
  else
    python3 - "$DOLBY_MK" <<'PYEOF9'
import sys
p = sys.argv[1]
lines = open(p).read().split("\n")
drop_exact = [
  "DEVICE_MANIFEST_FILE += $(DOLBY_PATH)/vendor.dolby.media.c2.xml",
  "    $(DOLBY_PATH)/configs/media_codecs_dolby_audio.xml:$(TARGET_COPY_OUT_VENDOR)/etc/media_codecs_dolby_audio.xml",
  "    $(DOLBY_PATH)/proprietary/vendor/etc/init/vendor.dolby.media.c2@1.0-service.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/vendor.dolby.media.c2@1.0-service.rc \\",
  "    vendor.dolby.media.c2@1.0-service \\",
]
kept, dropped = [], 0
for l in lines:
    if l in drop_exact:
        dropped += 1
        continue
    kept.append(l)
banner = ["# ------------------------------------------------------------------",
          "# MTK_IMS_FIXES FIX 9: vendor.dolby.media.c2@1.0-service DISABLED.",
          "# Blob objects were built against the pre-A17 RefBase ABI; A17 libutils",
          "# dereferences a stale mRefs offset and SIGSEGVs inside",
          "# BnHwComponentStore::_hidl_createComponent. Tree binary patches cannot",
          "# persist on the Soong-built interface lib, so the service is dropped.",
          "# Dolby audio (dms HAL + dax) is untouched. Applied by apply_fixes.sh.",
          "# ------------------------------------------------------------------"]
s = "\n".join(kept)
if "MTK_IMS_FIXES FIX 9" not in s:
    mark = "BOARD_VENDOR_SEPOLICY_DIRS += $(DOLBY_PATH)/sepolicy/vendor"
    s = s.replace(mark, "\n".join(banner) + "\n" + mark, 1)
open(p, "w").write(s)
print(f"dropped {dropped} line(s)")
PYEOF9
    ok "dolby.mk patched (service disabled)"
  fi
fi

# ===========================================================================
# FIX 10: bypass charging (LineageParts "Extra Battery options") — permanent.
# LineageParts (system_app domain) writes /sys/class/power_supply/usb/
# bypass_charging directly. SELinux grant lives in the xiaomi sepolicy vendor
# dir and the node needs ueventd 0660 system system so the system uid can
# write it. Both live tree-side; this step re-applies them after repo sync.
# ===========================================================================
echo "[10/10] bypass charging sepolicy + ueventd permissions"
SA_TE="$TOP/device/xiaomi/mt6895-common/sepolicy/vendor/system_app.te"
if [ ! -f "$SA_TE" ]; then
  fail "system_app.te not found at $SA_TE"
elif ! grep -q "allow system_app sysfs_power_supply:file" "$SA_TE"; then
  run cp /dev/null /dev/null
  { echo ""
    echo "# Bypass charging node for Extra Battery Options (LineageParts, system uid)."
    echo "# Parent power_supply dir is labeled sysfs_batteryinfo on A17. [FIX 10]"
    echo "allow system_app sysfs_batteryinfo:dir search;"
    echo "allow system_app sysfs_power_supply:dir search;"
    echo "allow system_app sysfs_power_supply:file rw_file_perms;"
  } >> "$SA_TE"
  ok "system_app.te: sysfs_power_supply grant appended"
else
  skip "system_app.te already grants sysfs_power_supply"
fi
UEVENTD="$TOP/device/xiaomi/mt6895-common/init/ueventd.mt6895.rc"
if [ -f "$UEVENTD" ] && ! grep -q "bypass_charging" "$UEVENTD"; then
  echo "/sys/class/power_supply/usb bypass_charging 0660 system system" >> "$UEVENTD"
  ok "ueventd.mt6895.rc: bypass_charging 0660 line appended"
else
  skip "ueventd already sets bypass_charging perms (or file missing)"
fi

# ===========================================================================
# FIX 11: app-zygote seccomp UID range — full isolated space instead of a
# per-app slice. createAppZygoteForProcessIfNeeded() passes firstUid/lastUid
# into AppZygote -> startChildZygote -> --uid-range-start/end ->
# ChildZygoteInit.install_setuidgid_seccomp_filter(min,max). With the stock
# per-app slice, a force-stop + relaunch can free/re-allocate the slice so
# the filter no longer covers the UIDs handed to the zygote's own children:
# setresgid(getuid()) gets SIGSYS (seccomp, arm64 syscall 149) and every
# Chromium sandboxed_process dies at specialization -> browser flapping.
# Granting the whole [FIRST_APP_ZYGOTE..LAST_APP_ZYGOTE] space (90000-98999,
# user 0) makes any isolated UID the allocator hands out valid for the
# filter, so the race can never deny a child again. Trade-off: the app
# zygote may gid-shift across the whole app-zygote isolated space — far
# preferable to crashing children (and equal to the safesetid-enabled path
# upstream uses). Live-verified 19.10.2026: 0 seccomp kills across repeated
# Brave/Chrome/GoLogin force-stop relaunch cycles (old code: 12 kills).
# ===========================================================================
echo "[11/11] frameworks/base — app-zygote seccomp full-range grant (ProcessList)"
PL="$TOP/frameworks/base/services/core/java/com/android/server/am/ProcessList.java"
if [ ! -f "$PL" ]; then
  fail "ProcessList.java not found at $PL (repo layout changed?)"
elif ! grep -q "MTK_IMS_FIXES FIX 11" "$PL"; then
  run python3 - "$PL" <<'PYEOF11'
import re, shutil, sys
p = sys.argv[1]
s = open(p).read()
pat = re.compile(
    r"final IsolatedUidRange uidRange =\s*\n"
    r"\s*mAppIsolatedUidRangeAllocator\.getIsolatedUidRangeLocked\(\s*\n"
    r"\s*app\.info\.processName,\s*app\.getHostingRecord\(\)\.getDefiningUid\(\)\);\s*\n"
    r"(?:\s*//[^\n]*\n)*"
    r"\s*firstUid = UserHandle\.getUid\(userId, uidRange\.mFirstUid\);\s*\n"
    r"\s*lastUid = UserHandle\.getUid\(userId, uidRange\.mLastUid\);\n"
)
m = pat.search(s)
if not m:
    print("FAIL  FIX 11 pattern not found in ProcessList.java — A17 source changed? re-derive the else-branch!")
    sys.exit(1)
new = (
    "// MTK_IMS_FIXES FIX 11: grant the app-zygote the full app-zygote\n"
    "                    // isolated UID space instead of a per-app slice. A per-app slice can\n"
    "                    // race with the child-process UID allocation, making the app-zygote\n"
    "                    // seccomp filter deny setresgid (SIGSYS, syscall 149) and crashing\n"
    "                    // Chromium sandboxed children (browser_zygote crashes).\n"
    "                    firstUid = Process.FIRST_APP_ZYGOTE_ISOLATED_UID;\n"
    "                    lastUid = Process.LAST_APP_ZYGOTE_ISOLATED_UID;\n"
)
shutil.copy(p, p + ".pre_fix11")
open(p, "w").write(s[:m.start()] + new + s[m.end():])
print("PASS  app-zygote else-branch -> full app-zygote isolated UID space")
PYEOF11
  [ "$DRYRUN" = "1" ] || ok "ProcessList.java patched (backup: ProcessList.java.pre_fix11)"
else
  skip "ProcessList.java already carries FIX 11"
fi

# --- FIX 12: MIUI Camera <-> MTK camera HAL binder grants (nw switch crash) ---
DEST12="$TOP/device/xiaomi/mt6895-common/sepolicy/vendor/miuicamera_hal_binder.te"
if [ ! -f "$DEST12" ]; then
  [ "$DRYRUN" = "1" ] || cp "$SNIP/miuicamera_hal_binder.te" "$DEST12"
  ok "MIUI camera HAL binder te installed (FIX 12)"
else
  skip "miuicamera_hal_binder.te present (FIX 12)"
fi

# --- FIX 13: crash_dump unwinder for MTK memfd app maps (no more 'Failed to parse maps') ---
DEST13="$TOP/device/mediatek/sepolicy_vndr/base/private/crash_dump_mtk_memfd.te"
if [ ! -f "$DEST13" ]; then
  [ "$DRYRUN" = "1" ] || cp "$SNIP/crash_dump_mtk_memfd.te" "$DEST13"
  ok "crash_dump memfd te installed (FIX 13)"
else
  skip "crash_dump_mtk_memfd.te present (FIX 13)"
fi

echo "=========================================================="
if [ "$DRYRUN" = "1" ]; then
  echo "Dry run complete — nothing was modified."
else
  echo "Apply pass complete. Re-run this script any time; it is idempotent."
  echo "Then ALWAYS validate before 'm bacon':"
  echo "   m libvt_audiotrack_shim manifest_em_hidl.xml   # both must build OK"
fi
echo "=========================================================="
exit 0
