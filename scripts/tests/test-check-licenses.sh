#!/bin/bash
# shellcheck disable=SC2015  # ok/no always return 0, so "A && ok || no" is a safe if-then-else
# check-licenses.sh against planted fixtures (no network, no real venv): a clean tree passes;
# GPL / AGPL packages, bundled components and vendored sources fail; LGPL passes only when
# whitelisted; GCC runtime exceptions and OR choices are understood; lock/venv drift, unknown
# licenses, HY-MT, a weakened allow/deny list, model-card mismatches and BlackHole fail.
# Run: scripts/tests/test-check-licenses.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cl="$here/../check-licenses.sh"

work="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/tt-licenses-test.XXXXXX")"
trap '/bin/rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
unset TALKTALK_ENGINE_HOME TALKTALK_HOME TALKTALK_BENCH_HOME

pass=0; fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
no() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; /usr/bin/sed 's/^/     | /' "$work/out"; }

MIT_TEXT='Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal'
GPL_TEXT='                    GNU GENERAL PUBLIC LICENSE
                       Version 3, 29 June 2007'
LGPL_TEXT='                   GNU LESSER GENERAL PUBLIC LICENSE
                       Version 2.1, February 1999'
AGPL_TEXT='                    GNU AFFERO GENERAL PUBLIC LICENSE
                       Version 3, 19 November 2007'

# pkg <site-packages> <name> <version> [METADATA header lines...]: plant a dist-info.
pkg() {
  local sp="$1" name="$2" version="$3" di
  shift 3
  di="$sp/$(printf '%s' "$name" | /usr/bin/tr '-' '_')-$version.dist-info"
  /bin/mkdir -p "$di"
  { printf 'Metadata-Version: 2.4\nName: %s\nVersion: %s\n' "$name" "$version"
    for h in "$@"; do printf '%s\n' "$h"; done
    printf '\nlong description\n'; } > "$di/METADATA"
  printf '%s' "$di"
}

# ---- base fixture: a clean tree -------------------------------------------------------------
b="$work/base"
/bin/mkdir -p "$b/root/scripts/lib" "$b/root/engine" "$b/root/Driver/third_party/libgood" \
  "$b/models/Fake-TTS@0123456789ab"
cat > "$b/root/scripts/lib/versions.sh" <<'EOF'
# shellcheck shell=bash
TT_LOCK_SHA256="fixture-lock"
TT_MODELS="tts-fake"
TT_LICENSE_ALLOW="Apache-2.0 MIT"; TT_MODEL_DENY="tencent/HY-MT"
TT_M_TTS_FAKE_REPO="acme/Fake-TTS"
TT_M_TTS_FAKE_REVISION="0123456789abcdef0123456789abcdef01234567"
TT_M_TTS_FAKE_ROLE="tts"; TT_M_TTS_FAKE_LICENSE="Apache-2.0"
EOF
printf 'goodpkg==1.0 \\\n    --hash=sha256:00\nfancy-pkg @ https://example.invalid/fancy.tar.gz \\\n    --hash=sha256:11\n' \
  > "$b/root/engine/requirements-engine.lock"
printf 'buildpkg==2.0 \\\n    --hash=sha256:22\n' > "$b/root/engine/requirements-build.lock"
printf '// swift-tools-version: 6.2\nlet package = 1\n' > "$b/root/Package.swift"
printf '%s\n' "$MIT_TEXT" > "$b/root/Driver/third_party/libgood/LICENSE"
printf -- '---\nlicense: apache-2.0\nlibrary_name: mlx-audio\n---\n# card\n' > "$b/models/Fake-TTS@0123456789ab/README.md"
bsp="$b/venv/lib/python3.12/site-packages"
pkg "$bsp" goodpkg 1.0 "License-Expression: MIT" >/dev/null
pkg "$bsp" fancy_pkg 0.6 "Classifier: License :: OSI Approved :: BSD License" >/dev/null
pkg "$bsp" buildpkg 2.0 "License: Apache 2.0 License" >/dev/null

fresh() {
  /bin/rm -rf "$work/t"; /bin/cp -R "$b" "$work/t"
  R="$work/t/root"; V="$work/t/venv"; M="$work/t/models"; SP="$V/lib/python3.12/site-packages"
}
# expect <description> <rc> <output pattern> [extra args]: run the gate on the current fixture.
expect() {
  local desc="$1" want="$2" pat="$3" rc=0
  shift 3
  "$cl" --root "$R" --venv "$V" --models-dir "$M" "$@" > "$work/out" 2>&1 || rc=$?
  if [ "$rc" = "$want" ] && /usr/bin/grep -q -E -- "$pat" "$work/out"; then ok "$desc"; else no "$desc (rc=$rc)"; fi
}

# 1. Clean tree.
fresh; expect "clean fixture passes" 0 'license gate: ok'
fresh; expect "clean fixture checks the vendored MIT license" 0 'ok   vendored Driver/third_party/libgood: LICENSE MIT'
fresh; expect "free-text License field is mapped" 0 'ok   package buildpkg 2.0: declares \(Apache-2.0\)'
fresh; expect "direct-URL lock pin is matched by name" 0 'ok   package fancy-pkg 0.6'

# 2. Packages: GPL / AGPL fail.
fresh; pkg "$SP" badgpl 1.0 "License-Expression: GPL-3.0-only" >/dev/null
expect "GPL package fails" 1 'FAIL package badgpl 1.0: .*GPL'
fresh; pkg "$SP" badagpl 1.0 "Classifier: License :: OSI Approved :: GNU Affero General Public License v3" >/dev/null
expect "AGPL classifier fails" 1 'FAIL package badagpl 1.0'
fresh; pkg "$SP" badgpl2 1.0 "License: GPLv2+" >/dev/null
expect "GPL in a free-text License field fails" 1 'FAIL package badgpl2 1.0'
fresh; pkg "$SP" sneaky 1.0 "License-Expression: MIT" "Classifier: License :: OSI Approved :: GNU General Public License v3 (GPLv3)" >/dev/null
expect "GPL classifier fails even with an MIT expression" 1 'FAIL package sneaky 1.0'
fresh; pkg "$SP" both 1.0 "License-Expression: MIT AND GPL-2.0-only" >/dev/null
expect "MIT AND GPL fails" 1 'FAIL package both 1.0'
fresh; pkg "$SP" dual 1.0 "License-Expression: GPL-2.0-only OR MIT" >/dev/null
expect "GPL OR MIT passes (MIT chosen)" 0 'ok   package dual 1.0'
fresh; di="$(pkg "$SP" gpltext 1.0 "License: see COPYING")"; printf '%s\n' "$GPL_TEXT" > "$di/COPYING"
expect "GPL license text without an SPDX line fails" 1 'FAIL package gpltext 1.0: license text COPYING reads as GPL'
fresh; di="$(pkg "$SP" agpltext 1.0 "License-Expression: MIT")"; /bin/mkdir -p "$di/licenses"
printf '%s\n' "$AGPL_TEXT" > "$di/licenses/LICENSE"
expect "AGPL text under licenses/ fails" 1 'FAIL package agpltext 1.0: license text licenses/LICENSE reads as AGPL'

# 3. LGPL: whitelist only.
fresh; pkg "$SP" lgplpkg 1.0 "License-Expression: LGPL-2.1-or-later" >/dev/null
expect "LGPL package not whitelisted fails" 1 'FAIL package lgplpkg 1.0: .*not in the LGPL whitelist \(lgplpkg\)'
fresh; pkg "$SP" lgplpkg 1.0 "License-Expression: LGPL-2.1-or-later" >/dev/null
expect "LGPL package passes when whitelisted" 0 'LGPL whitelist: lgplpkg' --lgpl-allow "lgplpkg"
fresh; pkg "$SP" num2words 0.5 "Classifier: License :: OSI Approved :: GNU Lesser General Public License v2 or later (LGPLv2+)" >/dev/null
expect "num2words (LGPL, §2.3) fails" 1 'FAIL package num2words 0.5'
fresh; di="$(pkg "$SP" lgpltext 1.0 "License: see COPYING.LESSER")"; printf '%s\n' "$LGPL_TEXT" > "$di/COPYING.LESSER"
expect "LGPL license text is LGPL, not GPL" 1 'FAIL package lgpltext 1.0: .*LGPL and not in the LGPL whitelist'

# 4. Bundled components (numpy / scipy format).
bundle() {
  local di
  di="$(pkg "$SP" numpy 2.4.3 "License-Expression: BSD-3-Clause")"; /bin/mkdir -p "$di/licenses"
  printf 'Copyright numpy\n\nName: GCC runtime library\nFiles: numpy/.dylibs/libgfortran*\nLicense: %s\n%s\n\nName: libquadmath\nLicense: LGPL-2.1-or-later\n' \
    "$1" "$GPL_TEXT" > "$di/licenses/LICENSE.txt"
}
fresh; bundle "GPL-3.0-or-later WITH GCC-exception-3.1"
expect "GPL WITH GCC-exception-3.1 passes, whitelisted libquadmath passes" 0 'numpy 2.4.3 \[libquadmath\].*LGPL whitelist: numpy:libquadmath'
fresh; bundle "GPL-3.0-or-later WITH GCC-exception-3.1"
expect "whitelisted component fails once it leaves the whitelist" 1 'FAIL package numpy 2.4.3 \[libquadmath\]' --lgpl-allow "scipy:libquadmath"
fresh; bundle "GPL-2.0-only WITH Classpath-exception-2.0"
expect "GPL with another exception fails" 1 'FAIL package numpy 2.4.3 \[GCC runtime library\]'
fresh; bundle "GPL-3.0-or-later"
expect "bundled plain GPL fails" 1 'FAIL package numpy 2.4.3 \[GCC runtime library\]'

# 5. Unknown / missing licenses, lock drift.
fresh; pkg "$SP" nolicense 1.0 >/dev/null
expect "package without license metadata fails" 1 'FAIL package nolicense 1.0: no license in METADATA'
fresh; pkg "$SP" oddlicense 1.0 "License-Expression: LicenseRef-Proprietary" >/dev/null
expect "unknown license fails" 1 'FAIL package oddlicense 1.0: .*unknown license'
fresh; /bin/rm -rf "$SP/goodpkg-1.0.dist-info"
expect "locked package missing from the venv fails" 1 'FAIL lock goodpkg: locked but not installed'
fresh; /bin/rm -rf "$SP/buildpkg-2.0.dist-info"; pkg "$SP" buildpkg 2.1 "License-Expression: MIT" >/dev/null
expect "build-lock version drift fails" 1 'FAIL lock buildpkg: lock pins 2.0, venv has 2.1'

# 6. Vendored sources.
fresh; /bin/mkdir -p "$R/Sources/CAudioCore/third_party/badlib"; printf '%s\n' "$GPL_TEXT" > "$R/Sources/CAudioCore/third_party/badlib/COPYING"
expect "vendored GPL fails" 1 'FAIL vendored Sources/CAudioCore/third_party/badlib: COPYING is GPL'
fresh; /bin/mkdir -p "$R/Driver/third_party/lgpllib"; printf '%s\n' "$LGPL_TEXT" > "$R/Driver/third_party/lgpllib/LICENSE"
expect "vendored LGPL fails (even whitelisted)" 1 'FAIL vendored Driver/third_party/lgpllib: LICENSE is LGPL' --lgpl-allow "lgpllib"
fresh; /bin/mkdir -p "$R/Driver/third_party/nolic"; printf 'int x;\n' > "$R/Driver/third_party/nolic/x.c"
expect "vendored source without a license file fails" 1 'FAIL vendored Driver/third_party/nolic: no LICENSE'
fresh; /bin/mkdir -p "$R/Driver/third_party/odd"; printf 'All rights reserved.\n' > "$R/Driver/third_party/odd/LICENSE"
expect "vendored unrecognised license fails" 1 'FAIL vendored Driver/third_party/odd: LICENSE: license not recognised'
fresh; /bin/mkdir -p "$R/Sources/CAudioCore/third_party/libfvad"
printf 'Redistribution and use in source and binary forms, with or without modification, are permitted.\nNeither the name of the copyright holder nor the names of its contributors may be used.\n' \
  > "$R/Sources/CAudioCore/third_party/libfvad/LICENSE"
expect "vendored BSD-3 passes" 0 'ok   vendored Sources/CAudioCore/third_party/libfvad: LICENSE BSD-3-Clause'
fresh; /bin/cp "$R/Driver/third_party/libgood/LICENSE" "$R/Driver/third_party/libgood/LICENSE.mit2"
printf 'This Apple software is supplied to you by Apple Inc. ("Apple") in consideration of your agreement\nApple grants you a personal, non-exclusive license, under Apple'"'"'s copyrights\n' \
  > "$R/Driver/third_party/libgood/LICENSE.apple2012"
expect "vendored Apple sample-code license (AML) passes, every LICENSE* file is read" 0 'ok   vendored Driver/third_party/libgood: LICENSE.apple2012 AML'
fresh; /bin/mkdir -p "$R/.build/checkouts/third_party/gplthing"; printf '%s\n' "$GPL_TEXT" > "$R/.build/checkouts/third_party/gplthing/COPYING"
expect ".build is not scanned" 0 'license gate: ok'

# 7. Models.
fresh; /usr/bin/sed -i '' 's/TT_M_TTS_FAKE_LICENSE="Apache-2.0"/TT_M_TTS_FAKE_LICENSE="GPL-3.0"/' "$R/scripts/lib/versions.sh"
expect "model with a GPL _LICENSE fails" 1 "FAIL models tts-fake: .*_LICENSE 'GPL-3.0' is not allowed"
fresh; /usr/bin/sed -i '' 's|acme/Fake-TTS|tencent/HY-MT1.5-1.8B|' "$R/scripts/lib/versions.sh"
expect "HY-MT model fails" 1 'FAIL models tts-fake: tencent/HY-MT1.5-1.8B is on the deny list'
fresh; /usr/bin/sed -i '' 's|TT_MODEL_DENY="tencent/HY-MT"|TT_MODEL_DENY=""|' "$R/scripts/lib/versions.sh"
expect "deny list without HY-MT fails" 1 'FAIL models TT_MODEL_DENY: must contain tencent/HY-MT'
fresh; /usr/bin/sed -i '' 's|TT_LICENSE_ALLOW="Apache-2.0 MIT"|TT_LICENSE_ALLOW="Apache-2.0 MIT GPL-3.0"|' "$R/scripts/lib/versions.sh"
expect "allow list with GPL fails" 1 'FAIL models TT_LICENSE_ALLOW'
fresh; printf -- '---\nlicense: cc-by-nc-4.0\n---\n' > "$M/Fake-TTS@0123456789ab/README.md"
expect "installed model card disagreeing with the pin fails" 1 'FAIL installed Fake-TTS@0123456789ab: model card says cc-by-nc-4.0'
fresh; /bin/mkdir -p "$M/HY-MT1.5-1.8B@aaaaaaaaaaaa"; printf -- '---\nlicense: apache-2.0\n---\n' > "$M/HY-MT1.5-1.8B@aaaaaaaaaaaa/README.md"
expect "installed HY-MT directory fails" 1 'FAIL installed HY-MT1.5-1.8B@aaaaaaaaaaaa'
fresh; /bin/mkdir -p "$M/Other@bbbbbbbbbbbb"; printf -- '---\nlicense: gpl-3.0\n---\n' > "$M/Other@bbbbbbbbbbbb/README.md"
expect "unpinned installed model with GPL fails" 1 "FAIL installed Other@bbbbbbbbbbbb: unpinned model with license 'gpl-3.0'"
fresh; /bin/mkdir -p "$R/tools/bench"
printf 'TB_BENCH_MODELS="tts-bench"\nTT_M_TTS_BENCH_REPO="acme/Bench"\nTT_M_TTS_BENCH_REVISION="1111111111111111111111111111111111111111"\nTT_M_TTS_BENCH_LICENSE="CC-BY-NC-4.0"\n' \
  > "$R/tools/bench/bench-pins.sh"
expect "bench pins are checked too" 1 "FAIL models tts-bench: acme/Bench _LICENSE 'CC-BY-NC-4.0'"

# 8. BlackHole.
fresh; printf '.package(url: "https://github.com/ExistentialAudio/BlackHole", from: "0.6.0")\n' >> "$R/Package.swift"
expect "BlackHole in Package.swift fails" 1 'FAIL blackhole Package.swift'
fresh; /bin/mkdir -p "$R/Driver/third_party/BlackHole"; printf '%s\n' "$MIT_TEXT" > "$R/Driver/third_party/BlackHole/LICENSE"
expect "vendored BlackHole fails" 1 'FAIL vendored Driver/third_party/BlackHole: BlackHole must not be vendored'

# 9. Venv selection and usage.
fresh; expect "--no-venv skips the package part" 0 'skip venv: --no-venv' --no-venv
fresh; rc=0; TALKTALK_ENGINE_HOME="$work/t/none" "$cl" --root "$R" --models-dir "$M" > "$work/out" 2>&1 || rc=$?
[ "$rc" = 0 ] && /usr/bin/grep -q 'skip venv: no engine venv' "$work/out" && ok "no installed venv: skipped with a note" || no "no venv skip (rc=$rc)"
fresh; rc=0; TALKTALK_ENGINE_HOME="$work/t/none" "$cl" --root "$R" --models-dir "$M" --require-venv > "$work/out" 2>&1 || rc=$?
[ "$rc" = 1 ] && ok "--require-venv without a venv fails" || no "--require-venv (rc=$rc)"
fresh; /bin/mkdir -p "$work/t/eh"; /bin/mv "$V" "$work/t/eh/venv"; printf 'lock=other build=x\n' > "$work/t/eh/venv/.talktalk-venv"
rc=0; TALKTALK_ENGINE_HOME="$work/t/eh" "$cl" --root "$R" --models-dir "$M" > "$work/out" 2>&1 || rc=$?
[ "$rc" = 0 ] && /usr/bin/grep -q 'not built from the current lock' "$work/out" && ok "venv from another lock: skipped with a note" || no "stale venv (rc=$rc)"
printf 'lock=fixture-lock build=x\n' > "$work/t/eh/venv/.talktalk-venv"; pkg "$work/t/eh/venv/lib/python3.12/site-packages" badgpl 1.0 "License-Expression: AGPL-3.0-only" >/dev/null
rc=0; TALKTALK_ENGINE_HOME="$work/t/eh" "$cl" --root "$R" --models-dir "$M" > "$work/out" 2>&1 || rc=$?
[ "$rc" = 1 ] && /usr/bin/grep -q 'FAIL package badgpl' "$work/out" && ok "venv found through the engine home is checked" || no "engine-home venv (rc=$rc)"
for args in "--bogus" "--venv" "--venv $work/nowhere"; do
  rc=0
  # shellcheck disable=SC2086
  "$cl" --root "$R" $args > "$work/out" 2>&1 || rc=$?
  [ "$rc" = 2 ] && ok "usage error exits 2: $args" || no "usage '$args' (rc=$rc)"
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
