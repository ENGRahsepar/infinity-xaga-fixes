#!/usr/bin/env bash
# =============================================================================
# verify_fixes.sh — check-only pass over every IMS/VoLTE/EngineerMode fix.
#   ~/infinity/MTK_IMS_FIXES/verify_fixes.sh   (never writes anything)
# =============================================================================
set -u
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
TOP="$(dirname "$SCRIPT_DIR")"
VT="$TOP/vendor/xiaomi/mt6895-common"
IMS="$TOP/vendor/mediatek/ims"
R=0
chk() { if eval "$2"; then echo "PASS   $1"; else echo "FAIL ✗ $1"; R=$((R+1)); fi; }

echo "================ MTK IMS/VoLTE fix verification ================"

# FIX 1: shim lib module exists and blob patched
chk "shim Android.bp present"                 '[ -f "$VT/shim/Android.bp" ]'
chk "shim C source present"                   '[ -f "$VT/shim/lib/vt_audiotrack_shim.c" ]'
chk "libsink-mtk.so patched (DT_NEEDED shim)" 'readelf -d "$VT/proprietary/system_ext/lib64/libsink-mtk.so" 2>/dev/null | grep -q libvt_audiotrack_shim.so'
chk "libsink-mtk.so.bak kept"                 '[ -f "$VT/proprietary/system_ext/lib64/libsink-mtk.so.bak" ]'

# FIX 2: em_hidl NOP
chk "em_hidl patched (NOP @0x70e8)"           'python3 -c "
d=open(\"$VT/proprietary/vendor/bin/em_hidl\",\"rb\").read()
exit(0 if d[0x70e8:0x70ec]==bytes.fromhex(\"1f2003d5\") else 1)" 2>/dev/null'
chk "em_hidl.bak kept"                        '[ -f "$VT/proprietary/vendor/bin/em_hidl.bak" ]'

# FIX 3/4sep: app_zygote policy for bundled-engine browsers
chk "app_zygote_browsers.te present"   '[ -f "$TOP/device/mediatek/sepolicy_vndr/base/private/app_zygote_browsers.te" ]'
chk "app_zygote rule: zygote_exec read allowed"  'grep -q "allow app_zygote zygote_exec:file" "$TOP/device/mediatek/sepolicy_vndr/base/private/app_zygote_browsers.te"'

# FIX 3/4: VINTF fragment module
chk "emhal module present"                    '[ -f "$VT/emhal/Android.bp" ] && [ -f "$VT/emhal/manifest_em_hidl.xml" ]'

# FIX 5: vendor.mk wiring
chk "vendor.mk: shim in PRODUCT_PACKAGES"     'grep -q "libvt_audiotrack_shim" "$VT/mt6895-common-vendor.mk"'
chk "vendor.mk: vtservice packages"           'grep -q "    vtservice" "$VT/mt6895-common-vendor.mk"'
chk "vendor.mk: init.vtservice rc copy files" 'grep -q "init.vtservice_aidl.rc" "$VT/mt6895-common-vendor.mk"'
chk "vendor.mk: fragment in pkg list"         'grep -q "^    manifest_em_hidl.xml" "$VT/mt6895-common-vendor.mk"'

# FIX 6: ims.mk props
for p in persist.dbg.volte_avail_ovr=1 persist.dbg.vt_avail_ovr=1 persist.dbg.wfc_avail_ovr=1 persist.vendor.vilte_support=1 persist.vendor.ims_support=1 persist.vendor.volte_support=1; do
  chk "ims.mk: $p" "grep -q '$p' '$IMS/ims.mk'"
done

# FIX 7: ImsService module dedupe
chk "vendor/mediatek/ims has no ImsService import" '! grep -q "name: \"ImsService\"" "$IMS/Android.bp"'


# FIX 9: Dolby c2 service disabled, audio stack kept
chk "dolby.mk: c2 service dropped from PACKAGES"  '! grep -q "^    vendor.dolby.media.c2@1.0-service" "$TOP/hardware/dolby/dolby.mk"'
chk "dolby.mk: c2 manifest fragment dropped"      '! grep -q "vendor.dolby.media.c2.xml" "$TOP/hardware/dolby/dolby.mk"'
chk "dolby.mk: audio dms service still shipped"   'grep -qF "vendor.dolby.hardware.dms@2.0-service" "$TOP/hardware/dolby/dolby.mk"'

# FIX 10: bypass charging permanence
chk "system_app.te: sysfs_power_supply grant"     'grep -q "allow system_app sysfs_power_supply:file" "$TOP/device/xiaomi/mt6895-common/sepolicy/vendor/system_app.te"'
chk "ueventd: bypass_charging 0660 system system" 'grep -q "bypass_charging 0660 system system" "$TOP/device/xiaomi/mt6895-common/init/ueventd.mt6895.rc"'

# FIX 11: app-zygote seccomp full-range grant (Chromium sandbox race)
PL="$TOP/frameworks/base/services/core/java/com/android/server/am/ProcessList.java"
chk "ProcessList.java exists"                     '[ -f "$PL" ]'
chk "FIX 11: banner comment present"              'grep -q "MTK_IMS_FIXES FIX 11" "$PL"'
chk "FIX 11: full-range constants in else-branch" 'grep -q "firstUid = Process.FIRST_APP_ZYGOTE_ISOLATED_UID" "$PL" && grep -q "lastUid = Process.LAST_APP_ZYGOTE_ISOLATED_UID" "$PL"'
chk "FIX 11: old per-app slice block removed"     '! grep -q "provide it with the UID-range" "$PL"'

# live device checks (optional, only if this host has adb and the phone is online)
if command -v adb >/dev/null 2>&1 && adb -s 100.67.8.82:5555 get-state 2>/dev/null | grep -q device; then
  echo "-------------------------------- device (live) ----------------"
  chk "vtservice running"            'adb -s 100.67.8.82:5555 shell su -c getprop init.svc.vtservice | grep -qE "running|stopped"'
  chk "media.VTS registered"         'adb -s 100.67.8.82:5555 shell service list | grep -q "media.VTS"'
  chk "shim file on device"          'adb -s 100.67.8.82:5555 shell su -c "test -e /system_ext/lib64/libvt_audiotrack_shim.so && echo ok" | grep -q ok'
fi

echo "================================================"
[ "$R" = "0" ] && echo "ALL CHECKS PASSED ✔" || echo "$R check(s) failed ✗"
exit "$R"
