#!/bin/bash
# check-licenses.sh: license gate (ARCHITECTURE.md §2.3, C9).
#
#   scripts/check-licenses.sh [--root DIR] [--venv DIR | --no-venv] [--require-venv]
#                             [--models-dir DIR]... [--lgpl-allow "LIST"] [-q]
#
# What it checks (exit 0 = pass, 1 = a check failed, 2 = usage error):
#   1. Python packages: every *.dist-info in the engine venv's site-packages. The declared license
#      (License-Expression, a short License field, License :: classifiers) and every bundled
#      component a license file names ("Name: … License: <SPDX>", as numpy/scipy ship) must be
#      permissive. GPL / AGPL fail (a GCC runtime library exception is accepted). LGPL passes only
#      when listed in the LGPL whitelist below (it may only be a transitive dependency inside the
#      external venv, never code in the app). Unknown licenses fail. Every package in
#      engine/requirements-engine.lock and engine/requirements-build.lock must be installed at the
#      locked version, so nothing in the lock goes unchecked.
#   2. Vendored sources: every directory under a third_party/ or vendor/ directory in the repo
#      (libASPL in Driver/third_party, libfvad in Sources/CAudioCore/third_party, …) must carry a
#      LICENSE / COPYING file that reads as MIT, BSD, Apache-2.0, ISC, Zlib or AML (Apple MIT, the
#      Apple sample-code license). Any GPL family license fails (LGPL too: vendored code is
#      linked into the app).
#   3. Models: TT_LICENSE_ALLOW ⊆ {Apache-2.0, MIT}; TT_MODEL_DENY still contains tencent/HY-MT;
#      every pinned model (versions.sh, tools/bench/bench-pins.sh) has an allowed _LICENSE and a
#      repo that is not denied. Installed model directories: the model card's `license:` must
#      match the pin; an unpinned directory must be allowed and must not be HY-MT.
#   4. BlackHole appears in no dependency list (Package.swift, Package.resolved, locks, pins,
#      vendored directory names).
#
# Venv: --venv DIR checks that venv as is. Default: $TALKTALK_ENGINE_HOME/venv (else
# ~/Library/Application Support/TalkTalk/engine/venv) when it exists and its .talktalk-venv stamp
# names the current lock; otherwise the venv part is skipped with a note (--require-venv makes
# that a failure). --models-dir defaults to the engine's models/ and the bench's models/
# (~/Library/Application Support/TalkTalk-bench/models) where they exist.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"

# LGPL whitelist: "<dist name>" (the package itself is LGPL) or "<dist name>:<component>" (a
# component bundled inside it, by the Name: in its license file, lower case).
# numpy / scipy wheels bundle libquadmath (LGPL-2.1-or-later), dynamically linked, in the venv.
LGPL_ALLOW_DEFAULT="numpy:libquadmath scipy:libquadmath"

usage() {
  /usr/bin/sed -n '3,4p' "$0" | /usr/bin/sed 's/^# \{0,1\}//' >&2
  exit 2
}

root="$(cd "$here/.." && pwd)"
engine_home="${TALKTALK_ENGINE_HOME:-${TALKTALK_HOME:-$HOME/Library/Application Support/TalkTalk}/engine}"
venv=""; venv_mode="auto"; require_venv=0; quiet=0
models_dirs=""; models_set=0
lgpl_allow="$LGPL_ALLOW_DEFAULT"
while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] || usage; root="$(cd "$2" && pwd)"; shift 2 ;;
    --venv) [ $# -ge 2 ] || usage; venv="$2"; venv_mode="explicit"; shift 2 ;;
    --no-venv) venv=""; venv_mode="off"; shift ;;
    --require-venv) require_venv=1; shift ;;
    --models-dir) [ $# -ge 2 ] || usage; models_dirs="$models_dirs$2
"; models_set=1; shift 2 ;;
    --lgpl-allow) [ $# -ge 2 ] || usage; lgpl_allow="$2"; shift 2 ;;
    -q) quiet=1; shift ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
[ "$venv_mode" = "explicit" ] && [ ! -d "$venv" ] && { printf 'check-licenses: no venv at %s\n' "$venv" >&2; exit 2; }

pins="$root/scripts/lib/versions.sh"
[ -f "$pins" ] || { printf 'check-licenses: %s not found\n' "$pins" >&2; exit 2; }
# shellcheck source=lib/versions.sh
. "$pins"
bench_models=""
if [ -f "$root/tools/bench/bench-pins.sh" ]; then
  # shellcheck source=../tools/bench/bench-pins.sh
  . "$root/tools/bench/bench-pins.sh"
  bench_models="${TB_BENCH_MODELS:-}"
fi

venv_note=""
if [ "$venv_mode" = "auto" ]; then
  if [ ! -d "$engine_home/venv" ]; then
    venv_note="no engine venv at $engine_home/venv (install the engine to check package licenses)"
  else
    stamp="$(/bin/cat "$engine_home/venv/.talktalk-venv" 2>/dev/null || true)"
    case "$stamp" in
      "lock=$TT_LOCK_SHA256 "*) venv="$engine_home/venv" ;;
      *) venv_note="engine venv was not built from the current lock (re-run the installer)" ;;
    esac
  fi
fi
[ "$venv_mode" = "off" ] && venv_note="--no-venv"
if [ "$models_set" = 0 ]; then
  bench_home="${TALKTALK_BENCH_HOME:-$HOME/Library/Application Support/TalkTalk-bench}"
  for d in "$engine_home/models" "$bench_home/models"; do
    [ -d "$d" ] && models_dirs="$models_dirs$d
"
  done
fi

# Model records for the checker: key, repo, license, installed directory name.
model_records() {
  local key
  for key in $TT_MODELS $bench_models; do
    printf 'MODEL\t%s\t%s\t%s\t%s\n' "$key" "$(tt_model_field "$key" REPO)" \
      "$(tt_model_field "$key" LICENSE)" "$(tt_model_dirname "$key" || true)"
  done
}

read -r -d '' checker <<'PY' || true
import os, re, sys
from email.parser import Parser

root = os.environ["CL_ROOT"]
venv = os.environ.get("CL_VENV", "")
venv_note = os.environ.get("CL_VENV_NOTE", "")
require_venv = os.environ.get("CL_REQUIRE_VENV") == "1"
quiet = os.environ.get("CL_QUIET") == "1"
lgpl_allow = set(os.environ.get("CL_LGPL_ALLOW", "").lower().split())
license_allow = os.environ.get("CL_LICENSE_ALLOW", "").split()
model_deny = os.environ.get("CL_MODEL_DENY", "").split()
models_dirs = [d for d in os.environ.get("CL_MODELS_DIRS", "").split("\n") if d]

fails = []
def ok(area, name, detail):
    if not quiet:
        print("ok   %s %s: %s" % (area, name, detail))
def fail(area, name, detail):
    fails.append(name)
    print("FAIL %s %s: %s" % (area, name, detail))
def skip(area, detail):
    print("skip %s: %s" % (area, detail))

# ---- SPDX-ish expressions -------------------------------------------------------------------
PERMISSIVE = {s.upper() for s in """MIT MIT-0 BSD BSD-2-Clause BSD-3-Clause BSD-3-Clause-Open-MPI
  0BSD ISC Apache-2.0 Zlib CC0-1.0 PSF-2.0 Python-2.0 CNRI-Python MPL-2.0 Unlicense BSL-1.0 HPND
  NCSA Unicode-3.0 Unicode-DFS-2016 BlueOak-1.0.0""".split()}
OK_EXCEPTIONS = {"GCC-EXCEPTION-3.1", "GCC-EXCEPTION-2.0"}   # runtime library exceptions
FREE_TEXT = {
    "mit": "MIT", "mit license": "MIT", "the mit license": "MIT",
    "apache 2.0": "Apache-2.0", "apache 2.0 license": "Apache-2.0", "apache license 2.0": "Apache-2.0",
    "apache license, version 2.0": "Apache-2.0", "apache software license": "Apache-2.0",
    "apache-2": "Apache-2.0", "apache": "Apache-2.0",
    "bsd": "BSD", "bsd license": "BSD", "new bsd license": "BSD-3-Clause", "3-clause bsd": "BSD-3-Clause",
    "isc": "ISC", "isc license": "ISC", "isc license (iscl)": "ISC",
    "python software foundation license": "PSF-2.0", "psf": "PSF-2.0",
    "mozilla public license 2.0 (mpl 2.0)": "MPL-2.0", "zlib/libpng license": "Zlib",
    "the unlicense (unlicense)": "Unlicense", "public domain": "Unlicense",
}
RANK = {"ok": 0, "lgpl": 1, "unknown": 2, "gpl": 3}

def from_free_text(s):
    t = s.strip().lower()
    if t in FREE_TEXT:
        return FREE_TEXT[t]
    if "affero" in t:
        return "AGPL"
    if "general public license" in t or re.search(r"\b[al]?gpl", t):
        if "lesser" in t or "library" in t or re.search(r"\blgpl", t):
            return "LGPL"
        return "AGPL" if re.search(r"\bagpl", t) else "GPL"
    return s.strip()

def atom_class(a):
    u = a.upper()
    if u.startswith("AGPL"):
        return "gpl"
    if u.startswith("LGPL"):
        return "lgpl"
    if u.startswith("GPL"):
        return "gpl"
    if u in PERMISSIVE:
        return "ok"
    return "unknown"

TOKEN = re.compile(r"\(|\)|[A-Za-z0-9.+:\-]+")
def evaluate(expr):
    """-> class of the expression: ok / lgpl / unknown / gpl (OR takes the best, AND the worst)."""
    toks = TOKEN.findall(expr)
    pos = [0]
    def peek():
        return toks[pos[0]].upper() if pos[0] < len(toks) else None
    def take():
        pos[0] += 1
        return toks[pos[0] - 1]
    def factor():
        if peek() == "(":
            take(); v = disj()
            if peek() == ")":
                take()
            return v
        if peek() is None:
            return "unknown"
        a = take()
        if peek() == "WITH":
            take()
            exc = take().upper() if peek() is not None else ""
            if atom_class(a) == "gpl" and exc in OK_EXCEPTIONS:
                return "ok"
        return atom_class(a)
    def conj():
        v = factor()
        while peek() == "AND":
            take(); w = factor()
            v = v if RANK[v] >= RANK[w] else w
        return v
    def disj():
        v = conj()
        while peek() == "OR":
            take(); w = conj()
            v = v if RANK[v] <= RANK[w] else w
        return v
    v = disj()
    return "unknown" if pos[0] != len(toks) else v

def judge(area, name, expr, lgpl_key, what):
    c = evaluate(expr)
    if c == "ok":
        ok(area, name, "%s %s" % (what, expr))
    elif c == "lgpl" and lgpl_key in lgpl_allow:
        ok(area, name, "%s %s (LGPL whitelist: %s)" % (what, expr, lgpl_key))
    elif c == "lgpl":
        fail(area, name, "%s %s is LGPL and not in the LGPL whitelist (%s)" % (what, expr, lgpl_key))
    elif c == "gpl":
        fail(area, name, "%s %s is GPL/AGPL" % (what, expr))
    else:
        fail(area, name, "%s %r: unknown license (add it to the gate after reading it)" % (what, expr))

# ---- license texts --------------------------------------------------------------------------
def norm(t):
    return re.sub(r"\s+", " ", t)

def text_class(t):
    t = norm(t)
    if "GNU AFFERO GENERAL PUBLIC LICENSE" in t:
        return "AGPL"
    if re.search(r"GNU (LESSER|LIBRARY) GENERAL PUBLIC LICENSE", t):
        return "LGPL"
    if "GNU GENERAL PUBLIC LICENSE" in t:
        return "GPL"
    if re.search(r"Apache License,? Version 2\.0", t, re.I):
        return "Apache-2.0"
    if "Permission is hereby granted, free of charge" in t:
        return "MIT"
    if "Redistribution and use in source and binary forms" in t:
        return "BSD-3-Clause" if re.search(r"Neither the name|names of (its|the) contributors", t) else "BSD-2-Clause"
    if re.search(r"Permission to use, copy, modify, and(/or)? distribute this software for any purpose", t):
        return "ISC"
    if "provided 'as-is'" in t and "altered source versions" in t:
        return "Zlib"
    if "This Apple software is supplied to you by Apple" in t and "grants you a personal, non-exclusive license" in t:
        return "AML"   # Apple MIT License (Apple sample code; libASPL's LICENSE.apple2012)
    return None

COMPONENT = re.compile(r"^\s*(Name|License):\s*(\S.*?)\s*$", re.M)
def components(t):
    """[(name, expr)] from 'Name: x … License: y' blocks (numpy / scipy bundled-license format)."""
    out, name = [], None
    for m in COMPONENT.finditer(t):
        if m.group(1) == "Name":
            name = m.group(2)
        else:
            out.append((name or "?", m.group(2)))
    return out

def read(p):
    with open(p, encoding="utf-8", errors="replace") as f:
        return f.read()

# ---- 1. Python packages ---------------------------------------------------------------------
def canon(n):
    return re.sub(r"[-_.]+", "-", n).lower()

def lock_pins():
    pins = {}
    for lock in ("engine/requirements-engine.lock", "engine/requirements-build.lock"):
        p = os.path.join(root, lock)
        if not os.path.exists(p):
            continue
        for line in read(p).splitlines():
            m = re.match(r"^([A-Za-z0-9][A-Za-z0-9._-]*)\s*(==\s*([^\s;\\]+)|@\s*\S+)", line)
            if m:
                pins[canon(m.group(1))] = m.group(3)   # None for a direct URL pin
    return pins

def license_files(di):
    out = []
    for dirpath, _, files in os.walk(di):
        rel = os.path.relpath(dirpath, di)
        for f in sorted(files):
            if rel.split(os.sep)[0] == "licenses" or re.match(r"(?i)(licen[cs]e|copying|notice)", f):
                out.append(os.path.join(dirpath, f))
    return sorted(out)

def check_package(di):
    md = Parser().parsestr(read(os.path.join(di, "METADATA")), headersonly=True)
    name, version = md.get("Name", "?"), md.get("Version", "?")
    dist = canon(name)
    label = "%s %s" % (dist, version)
    declared = []
    if md.get("License-Expression"):
        declared.append(md["License-Expression"].strip())
    lic = (md.get("License") or "").strip()
    long_lic = ""
    if lic and "\n" not in lic and len(lic) <= 120:
        declared.append(from_free_text(lic))
    elif lic:
        long_lic = lic
    for c in md.get_all("Classifier") or []:
        if c.startswith("License ::") and c.strip() != "License :: OSI Approved":
            declared.append(from_free_text(c.split("::")[-1]))
    if not declared:
        fail("package", label, "no license in METADATA")
    else:
        judge("package", label, " AND ".join("(%s)" % d for d in declared), dist, "declares")
    texts = [("METADATA License field", long_lic)] if long_lic else []
    texts += [(os.path.relpath(p, di), read(p)) for p in license_files(di)]
    for where, t in texts:
        comps = components(t)
        for cname, expr in comps:
            judge("package", "%s [%s]" % (label, cname), expr, "%s:%s" % (dist, cname.lower()),
                  "bundles (%s)" % where)
        if not comps:
            k = text_class(t)
            if k in ("GPL", "AGPL", "LGPL"):
                judge("package", label, k, dist, "license text %s reads as" % where)
    return dist, version

def check_venv():
    if not venv:
        if require_venv:
            fail("venv", "venv", venv_note)
        else:
            skip("venv", venv_note)
        return
    sps = []
    libdir = os.path.join(venv, "lib")
    if os.path.isdir(libdir):
        sps = [os.path.join(libdir, d, "site-packages") for d in sorted(os.listdir(libdir))
               if d.startswith("python") and os.path.isdir(os.path.join(libdir, d, "site-packages"))]
    if not sps:
        fail("venv", venv, "no lib/python*/site-packages")
        return
    installed = {}
    for sp in sps:
        for d in sorted(os.listdir(sp)):
            di = os.path.join(sp, d)
            if d.endswith(".dist-info") and os.path.isfile(os.path.join(di, "METADATA")):
                dist, version = check_package(di)
                installed[dist] = version
    for dist, version in sorted(lock_pins().items()):
        if dist not in installed:
            fail("lock", dist, "locked but not installed in %s: its license cannot be checked" % venv)
        elif version is not None and installed[dist] != version:
            fail("lock", dist, "lock pins %s, venv has %s" % (version, installed[dist]))

# ---- 2. vendored sources --------------------------------------------------------------------
SKIP_DIRS = {".git", ".build", "build", ".claude", "node_modules", ".swiftpm"}
def check_vendored():
    found = 0
    for dirpath, dirs, _ in os.walk(root):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
        if os.path.basename(dirpath) not in ("third_party", "vendor"):
            continue
        for comp in list(dirs):
            cdir = os.path.join(dirpath, comp)
            rel = os.path.relpath(cdir, root)
            found += 1
            if re.search(r"(?i)blackhole|existentialaudio", comp):
                fail("vendored", rel, "BlackHole must not be vendored")
            lfs = sorted(f for f in os.listdir(cdir)
                         if re.match(r"(?i)(licen[cs]e|copying)", f) and os.path.isfile(os.path.join(cdir, f)))
            if not lfs:
                fail("vendored", rel, "no LICENSE / COPYING file")
                continue
            for f in lfs:
                k = text_class(read(os.path.join(cdir, f)))
                if k is None:
                    fail("vendored", rel, "%s: license not recognised (MIT/BSD/Apache-2.0/ISC/Zlib/AML expected)" % f)
                elif k in ("GPL", "AGPL", "LGPL"):
                    fail("vendored", rel, "%s is %s (vendored code is linked into the app)" % (f, k))
                else:
                    ok("vendored", rel, "%s %s" % (f, k))
        dirs[:] = []   # components are not searched for nested third_party dirs
    if found == 0:
        skip("vendored", "no third_party/ or vendor/ directories")

# ---- 3. models ------------------------------------------------------------------------------
HF_LICENSE = {"apache-2.0": "Apache-2.0", "mit": "MIT"}
def card_license(d):
    p = os.path.join(d, "README.md")
    if not os.path.isfile(p):
        return None
    m = re.match(r"---\s*\n(.*?)\n---", read(p), re.S)
    if not m:
        return None
    l = re.search(r"^license:\s*['\"]?([^'\"\s]+)", m.group(1), re.M)
    return HF_LICENSE.get(l.group(1).lower(), l.group(1)) if l else None

def denied(repo):
    r = repo.lower()
    return any(r.startswith(d.lower()) for d in model_deny) or "hy-mt" in r

def check_models(records):
    bad_allow = [l for l in license_allow if l not in ("Apache-2.0", "MIT")]
    if bad_allow or not license_allow:
        fail("models", "TT_LICENSE_ALLOW", "must be a subset of Apache-2.0 MIT, is %r" % " ".join(license_allow))
    else:
        ok("models", "TT_LICENSE_ALLOW", " ".join(license_allow))
    if not any(d.lower() == "tencent/hy-mt" for d in model_deny):
        fail("models", "TT_MODEL_DENY", "must contain tencent/HY-MT (C9), is %r" % " ".join(model_deny))
    else:
        ok("models", "TT_MODEL_DENY", " ".join(model_deny))
    by_dir = {}
    for key, repo, lic, dirname in records:
        if not repo:
            fail("models", key, "no _REPO pin")
            continue
        by_dir[dirname] = (key, lic)
        if denied(repo):
            fail("models", key, "%s is on the deny list" % repo)
        elif lic not in license_allow or lic not in ("Apache-2.0", "MIT"):
            fail("models", key, "%s _LICENSE %r is not allowed" % (repo, lic))
        else:
            ok("models", key, "%s %s" % (repo, lic))
    for md in models_dirs:
        if not os.path.isdir(md):
            continue
        for d in sorted(os.listdir(md)):
            p = os.path.join(md, d)
            if not os.path.isdir(p):
                continue
            card = card_license(p)
            if "hy-mt" in d.lower():
                fail("installed", d, "HY-MT model installed in %s" % md)
            elif d in by_dir:
                key, lic = by_dir[d]
                if card is not None and card != lic:
                    fail("installed", d, "model card says %s, pin says %s" % (card, lic))
                else:
                    ok("installed", d, "model card %s" % (card or "(none)"))
            elif card in ("Apache-2.0", "MIT"):
                ok("installed", d, "unpinned, model card %s" % card)
            else:
                fail("installed", d, "unpinned model with license %r" % card)

# ---- 4. BlackHole ---------------------------------------------------------------------------
def check_blackhole():
    hits = 0
    for rel in ("Package.swift", "Package.resolved", "engine/requirements-engine.lock",
                "engine/requirements-build.lock", "engine/requirements-engine.in",
                "engine/requirements-build.in", "scripts/lib/versions.sh", "tools/bench/bench-pins.sh"):
        p = os.path.join(root, rel)
        if os.path.isfile(p) and re.search(r"(?i)blackhole|existentialaudio", read(p)):
            fail("blackhole", rel, "mentions BlackHole")
            hits += 1
    if hits == 0:
        ok("blackhole", "dependencies", "no BlackHole in Package.swift, locks or pins")

records = []
for line in sys.stdin.read().splitlines():
    f = line.split("\t")
    if f[0] == "MODEL" and len(f) == 5:
        records.append(tuple(f[1:]))
check_venv()
check_vendored()
check_models(records)
check_blackhole()
if fails:
    print("\nlicense gate: %d failure(s)" % len(fails))
    sys.exit(1)
print("\nlicense gate: ok")
PY

model_records | CL_ROOT="$root" CL_VENV="$venv" CL_VENV_NOTE="$venv_note" CL_REQUIRE_VENV="$require_venv" \
  CL_QUIET="$quiet" CL_LGPL_ALLOW="$lgpl_allow" CL_LICENSE_ALLOW="${TT_LICENSE_ALLOW:-}" \
  CL_MODEL_DENY="${TT_MODEL_DENY:-}" CL_MODELS_DIRS="$models_dirs" \
  /usr/bin/python3 -I -B -c "$checker"
