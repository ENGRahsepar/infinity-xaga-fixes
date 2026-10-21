#!/bin/bash
# Local sepolicy neverallow check - NO full build needed.
#
# It re-runs the build's own m4 rule script (which produces the exact
# .conf the build feeds to checkpolicy) with the kit's new .te files added
# to the input list, then runs the very same checkpolicy command the build
# uses:
#
#   out/host/linux-x86/bin/checkpolicy -M -c 30 -o <bin> <conf>
#
# Exit 0 => no neverallow violation => the ROM will build.
#
# Usage: bash MTK_IMS_FIXES/check_policy.sh
set -euo pipefail

TOP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$TOP"
OUT=/tmp/opencode
mkdir -p "$OUT"

RULE="$(ls -t out/soong/rule_builder_scripts/*.sh 2>/dev/null | head -1 || true)"
if [ -z "$RULE" ]; then
  echo "!! no rule script found - run a build once (it stops at the sepolicy step)"
  echo "   or find it with: ls out/soong/rule_builder_scripts/*.sh"
  exit 1
fi
echo "==> using rule script: $RULE"

python3 - "$RULE" "$OUT/gen_policy.sh" << 'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
ins = [
 ("device/mediatek/sepolicy_vndr/base/vendor/platform_app.te",
  "device/mediatek/sepolicy_vndr/base/vendor/platform_app_36.te"),
 ("device/mediatek/sepolicy_vndr/base/private/app_zygote_browsers.te",
  "device/mediatek/sepolicy_vndr/base/private/miuicamera_platform_app_36.te"),
]
for anchor, add in ins:
    if anchor in s and add not in s:
        s = s.replace(anchor, anchor + " " + add, 1)
s = s.replace(
  "out/soong/.intermediates/system/sepolicy/sepolicy_neverallows.checkpolicy.conf/android_common/sepolicy_neverallows.checkpolicy.conf",
  "/tmp/opencode/policy_check.conf")
open(dst, "w").write(s)
PYEOF

echo "==> generating policy conf ..."
sh "$OUT/gen_policy.sh" >/dev/null

echo "==> checkpolicy (neverallow check) ..."
if out/host/linux-x86/bin/checkpolicy -M -c 30 -o "$OUT/policy.bin" "$OUT/policy_check.conf" 2>&1 \
     | grep -viE "hal_vm_capabilities|crosvm_vendor|^$"; then
  :
fi
rc=${PIPESTATUS[0]}
if [ "$rc" = "0" ]; then
  echo "==> RESULT: PASS - no neverallow violation, the build will get past sepolicy"
else
  echo "==> RESULT: FAIL (checkpolicy rc=$rc) - see the violations above"
fi
exit "$rc"
