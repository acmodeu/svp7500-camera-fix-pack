#!/usr/bin/env bash
# ===========================================================================
# selftest.sh — is this PACKAGE internally consistent?
#
# Hardware-free, root-free, side-effect-free. It does not touch /usr/src,
# /lib/modules, /etc or /boot, does not run dkms, and does not load a module.
# It answers one question: if a stranger downloaded this repo right now and ran
# install.sh, would the installer find everything it is about to install?
#
# It exists because of a specific failure. install.sh looked for modules in
# kernel/<name>/ while the published package ships dkms/<name>-<version>/. It
# found none of them, printed "! <name> not in package, skipping" four times,
# then printed "==> Done" and exited 0. It had installed nothing, for every
# user who ever ran it, and nothing in the repo noticed.
#
# So the rule this file enforces is: a step that did not happen must not be
# able to report success. Every check below is a thing that was silently
# skipped, or could be. It is deliberately paranoid about the package, and
# says nothing whatsoever about whether any camera works -- it cannot, and it
# never claims to.
#
#   ./tools/selftest.sh          human output
#   ./tools/selftest.sh -q       only failures and the summary
#   ./tools/selftest.sh --prove  test the test: build one correct throwaway
#                                package and a dozen broken ones -- each
#                                carrying a bug that shipped or nearly did --
#                                and assert this script accepts the first and
#                                rejects every other. A check nobody has ever
#                                seen fail is not yet a check. The correct
#                                package is not a formality: it is the only
#                                thing standing between a strict check and a
#                                false accusation against working code.
#
# Exit status: 0 = every check passed, 1 = at least one FAIL.
# WARN never changes the exit status, so it is reserved for things that are
# true today and could rot tomorrow (two byte-identical copies of one script).
# Anything that means an instruction in this package cannot work -- a path that
# is not there, two files with one name, a module nobody installs -- is a FAIL.
# A warning that CI ignores is how the verify.sh split shipped.
# ===========================================================================
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INSTALL="$ROOT/install.sh"
README="$ROOT/README.md"
QUIET=0
[[ ${1:-} == -q || ${1:-} == --quiet ]] && QUIET=1

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  C_G=$'\033[32m'; C_R=$'\033[31m'; C_Y=$'\033[33m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else
  C_G=; C_R=; C_Y=; C_B=; C_0=
fi

n_pass=0; n_fail=0; n_warn=0
declare -a FAILS=() WARNS=()

section(){ [[ $QUIET -eq 1 ]] || printf '\n%s== %s%s\n' "$C_B" "$*" "$C_0"; }
info(){ [[ $QUIET -eq 1 ]] || printf '       %s\n' "$*"; }
pass(){ n_pass=$((n_pass+1)); [[ $QUIET -eq 1 ]] || printf '  %sPASS%s %s\n' "$C_G" "$C_0" "$*"; }
fail(){ n_fail=$((n_fail+1)); FAILS+=("$1"); printf '  %sFAIL%s %s\n' "$C_R" "$C_0" "$1"
        shift; local l; for l in "$@"; do printf '       %s\n' "$l"; done; }
warn(){ n_warn=$((n_warn+1)); WARNS+=("$1")
        [[ $QUIET -eq 1 ]] && return 0
        printf '  %sWARN%s %s\n' "$C_Y" "$C_0" "$1"
        shift; local l; for l in "$@"; do printf '       %s\n' "$l"; done; }

rel(){ printf '%s' "${1#"$ROOT"/}"; }

# ---------------------------------------------------------------------------
# A shell script as LOGICAL lines: backslash continuations joined, whole-line
# comments dropped, and every line tagged CAND or PLAIN.
#
# CAND marks a first-match-wins candidate list --
#     for c in "$HERE/dkms/x.patch" "$HERE/kernel/x.patch"; do
#       [[ -f $c ]] && { P=$c; break; }
#     done
# -- where only ONE of the paths has to exist. A for-loop with no break (and no
# `return 0`) is an assert-EACH loop, like preflight's "package is missing $f"
# check: every path in it is independently required.
#
# A loop over ONE word is neither: there is nothing to fall back to, so the
# single path has to work no matter what break or return it contains. Tagging
# it CAND exempted it from the "must resolve for every module" rule, and that
# is precisely the shape of the bug that shipped --
#     for d in "$HERE/kernel/$m"; do ... return 0; done
# -- so the word list is counted first and only a list of two or more is
# eligible to be a candidate list.
#
# The distinction matters because the reference checker used to group by
# basename and pass a group when any member existed. That is correct for a real
# candidate list and wrong for everything else: it is how `git rm verify.sh`
# still passed while install.sh's last screen told every user to run it.
logical_lines(){
  awk '
    /^[[:space:]]*#/ { next }
    { line=$0
      while (line ~ /\\$/) { sub(/\\[[:space:]]*$/,"",line); if ((getline nxt)<=0) break; line=line " " nxt }
      L[++n]=line }
    END {
      for (i=1;i<=n;i++) {
        tag="PLAIN"
        if (L[i] ~ /(^|[;&|{}][[:space:]]*|[[:space:]])for[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+in[[:space:]].*;[[:space:]]*do([[:space:]]|$)/) {
          lst=L[i]
          sub(/^.*[[:space:]]in[[:space:]]+/,"",lst)
          sub(/;[[:space:]]*do([[:space:]].*)?$/,"",lst)
          nw=split(lst,W,/[[:space:]]+/)
          for (j=i;(nw>1)&&(j<=n);j++) {
            if (j>i && L[j] ~ /^[[:space:]]*done([[:space:]]|;|$)/) break
            if (L[j] ~ /(^|[^A-Za-z0-9_])break([^A-Za-z0-9_]|$)/ ||
                L[j] ~ /(^|[^A-Za-z0-9_])return[[:space:]]+0([^0-9]|$)/) { tag="CAND"; break }
          }
        }
        print tag "\t" L[i]
      }
    }' "$1"
}

# ---------------------------------------------------------------------------
# --prove: do these checks actually fire?
#
# Builds throwaway packages in a temp directory -- one correct, then one copy per
# regression, each carrying exactly one real bug that has shipped or nearly did --
# and asserts this script rejects each of them and accepts the correct one. A
# check nobody has watched fail is not yet a check, and every one of these was a
# WARN or a blind spot the day the package went out. Nothing outside the temp
# directory is touched: no dkms, no modules, no root.
if [[ ${1:-} == --prove ]]; then
  t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
  mk_pkg(){ # $1 dir, $2 = search path expression install.sh will use
    mkdir -p "$1/tools" "$1/dkms/demo-1.0" "$1/udev" "$1/howdy"
    cat > "$1/install.sh" <<EOF
#!/usr/bin/env bash
# Tested on: kernels 1.0 through 2.0
set -euo pipefail
HERE="\$(cd "\$(dirname "\$(readlink -f "\$0")")" && pwd)"
REQUIRED_MODULES=(demo)
find_src(){ local m=\$1 d; for d in $2; do [[ -d \$d && -f \$d/dkms.conf ]] && { echo "\${d%/}"; return 0; }; done; return 1; }
for m in "\${REQUIRED_MODULES[@]}"; do find_src "\$m" || echo "! \$m not in package, skipping"; done
install -m 0644 "\$HERE/udev/99-hm1092-ir-led.rules" /etc/udev/rules.d/
install -m 0444 "\$HERE/howdy/ir_reader.py" /usr/lib/howdy/recorders/ir_reader.py
patch -p0 -d / < "\$HERE/howdy/video_capture.patch"
echo "==> Done"
echo "   sudo \$HERE/verify.sh   check the whole stack"
bad "package is missing module 'x' — this clone/tarball is incomplete, re-download it"
EOF
    printf 'PACKAGE_NAME="demo"\nPACKAGE_VERSION="1.0"\nBUILT_MODULE_NAME[0]="demo"\n' > "$1/dkms/demo-1.0/dkms.conf"
    printf 'MAKE[0]="make -C ${kernel_source_dir} M=${dkms_tree}/${PACKAGE_NAME}/${PACKAGE_VERSION}/build modules"\n' \
      >> "$1/dkms/demo-1.0/dkms.conf"
    printf 'obj-m += demo.o\n' > "$1/dkms/demo-1.0/Makefile"
    : > "$1/dkms/demo-1.0/demo.c"
    { printf '# demo\nkernels 1.0 through 2.0\n\nAfter the reboot:\n\n    sudo ./tools/verify.sh\n'
      printf '\n| line | meaning |\n|---|---|\n'
      printf '| `✗ package is missing module '"'"'<name>'"'"' — this clone/tarball is incomplete, re-download it` | packaging bug |\n'
    } > "$1/README.md"
    printf 'ACTION=="add", KERNEL=="flash*", MODE="0660"\n' > "$1/udev/99-hm1092-ir-led.rules"
    printf 'class ir_reader:\n    pass\n' > "$1/howdy/ir_reader.py"
    printf -- '--- a/video_capture.py\n+++ b/video_capture.py\n' > "$1/howdy/video_capture.patch"
    # The shared-library shape, in the CORRECT package on purpose: detection
    # lives in one file and the consumer sources it. If this script cannot
    # follow `source`, it reports these LD_* reads as unset-variable bugs --
    # a red CI on correct code, which is how the library gets abandoned and
    # the duplicated detection drifts apart again. The two libraries source
    # each other, so a missing cycle guard hangs instead of finishing.
    #
    # $LIBD, not a literal, so this file does not appear to REFERENCE the
    # throwaway libraries it writes -- the path checker reads this script too,
    # and would demand the package ship them.
    local LIBD=tools
    cat > "$1/$LIBD/verify.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
ROOT=\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)
. "\$ROOT/$LIBD/lib-demo.sh"
echo "verification, canonical copy: \$LD_DEMO \$LD_DEEP"
EOF
    cat > "$1/$LIBD/lib-demo.sh" <<EOF
#!/usr/bin/env bash
[[ -n \${LIB_DEMO_LOADED:-} ]] && return 0
LIB_DEMO_LOADED=1
LIB_ROOT=\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)
. "\$LIB_ROOT/$LIBD/lib-deep.sh"
LD_DEMO=demo
EOF
    cat > "$1/$LIBD/lib-deep.sh" <<EOF
#!/usr/bin/env bash
[[ -n \${LIB_DEEP_LOADED:-} ]] && return 0
LIB_DEEP_LOADED=1
DEEP_ROOT=\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)
. "\$DEEP_ROOT/$LIBD/lib-demo.sh"
LD_DEEP=deep
EOF
    ln -s tools/verify.sh "$1/verify.sh"
    chmod +x "$1/install.sh" "$1/$LIBD/verify.sh" "$1/$LIBD/lib-demo.sh" "$1/$LIBD/lib-deep.sh"
    cp "${BASH_SOURCE[0]}" "$1/tools/selftest.sh"; chmod +x "$1/tools/selftest.sh"
  }
  GOOD_SEARCH='"$HERE"/dkms/"$m"-*/ "$HERE/dkms/$m" "$HERE/kernel/$m"'
  rc=0
  # mutate <name> -- a copy of the good package for the caller to break
  mutate(){ cp -a "$t/good" "$t/$1"; printf '%s' "$t/$1"; }
  # Every fixture runs under a time limit. Following `source` between package
  # files can cycle, and a check that hangs is worse than one that fails: CI
  # goes yellow for twenty minutes and the next person disables it. A timeout
  # here turns that regression into an ordinary FAIL with a name.
  TMO=(); command -v timeout >/dev/null 2>&1 && TMO=(timeout 120)
  # expect_fail <dir> <substring> <what it is>
  expect_fail(){
    local d=$1 want=$2 label=$3 out e
    out=$(NO_COLOR=1 "${TMO[@]}" "$d/tools/selftest.sh" 2>&1); e=$?
    [[ $e -eq 124 ]] && { printf '  FAIL  %s TIMED OUT — the checker hangs on it (a cycle it does not guard?)\n' "$(basename "$d")"; rc=1; return; }
    if [[ $e -ne 0 ]] && grep -qF "$want" <<<"$out"; then
      printf '  PASS  rejects %s\n' "$label"
    elif [[ $e -eq 0 ]]; then
      printf '  FAIL  %s exits 0 — %s ships green\n' "$(basename "$d")" "$label"; rc=1
    else
      printf '  FAIL  %s failed for the WRONG reason (no "%s" in the output)\n' "$(basename "$d")" "$want"; rc=1
    fi
  }

  mk_pkg "$t/good" "$GOOD_SEARCH"
  out_g=$(NO_COLOR=1 "${TMO[@]}" "$t/good/tools/selftest.sh" 2>&1); eg=$?
  if [[ $eg -eq 124 ]]; then
    printf '  FAIL  the CORRECT package TIMED OUT — the checker hangs (an unguarded source cycle?)\n'; rc=1
  elif [[ $eg -eq 0 ]]; then
    printf '  PASS  accepts a correctly laid out package (including a script that sources a library that sources it back)\n'
  else
    printf '  FAIL  rejects a CORRECT package — false positive, every proof below is meaningless\n'
    printf '%s\n' "$out_g" | sed -n 's/^  FAIL/        FAIL/p'; rc=1
  fi

  # 1. THE bug: the installer looks where the package does not put the modules.
  mk_pkg "$t/layout" '"$HERE/kernel/$m"'
  expect_fail "$t/layout" "CANNOT FIND module 'demo'" \
    "the shipped layout mismatch (installer looks in kernel/, package ships dkms/)"

  # 2. The same mistake one function later: a module path built outside the
  #    candidate list. install.sh catches this at runtime; the package test did not.
  d=$(mutate copy-step-wrong-layout)
  printf 'cp -r "$HERE/kernel/$m/." /tmp/staging\n' >> "$d/install.sh"
  expect_fail "$d" "outside its candidate list" "a module path expression that resolves for no module"

  # 3. Divergent duplicate: the verify.sh split that shipped. install.sh points
  #    at the root copy, the README at tools/ — and they are different files.
  d=$(mutate divergent-verify)
  rm "$d/verify.sh"; cp "$d/tools/verify.sh" "$d/verify.sh"
  printf 'echo "STALE COPY: no stale-module check here"\n' >> "$d/verify.sh"
  expect_fail "$d" "exists twice with DIFFERENT contents" "two verify.sh files with different contents"
  expect_fail "$d" "point at DIFFERENT files named verify.sh" \
    "install.sh and the README sending users to different files"

  # 4. Either half of the pair deleted. Grouping by basename used to pass both
  #    of these at "1 of 2 candidate paths present".
  d=$(mutate tools-verify-deleted); rm "$d/tools/verify.sh"
  expect_fail "$d" "DANGLING symlink" "the canonical copy deleted out from under the root name"
  d=$(mutate root-verify-deleted); rm "$d/verify.sh"
  expect_fail "$d" "referenced but MISSING from the package: verify.sh" \
    "install.sh's own next-steps command pointing at a file that is not shipped"

  # 5. A documented root-level command that does not exist. The reference
  #    checker only knew subdirectory paths, so the README's entry point --
  #    the first thing a stranger types -- was the one path nothing checked.
  d=$(mutate readme-phantom-command)
  printf '\nQuick start:\n\n    sudo ./setup-ir.sh --all\n' >> "$d/README.md"
  expect_fail "$d" "referenced but MISSING from the package: setup-ir.sh" \
    "a README quick-start naming a script that was never committed"

  # 6. A module shipped but never wired into install.sh: a maintainer adds a
  #    sensor driver for someone else's board and forgets the *_MODULES line.
  d=$(mutate module-not-wired); mkdir -p "$d/dkms/extra-1.0"
  printf 'PACKAGE_NAME="extra"\nPACKAGE_VERSION="1.0"\nBUILT_MODULE_NAME[0]="extra"\n' > "$d/dkms/extra-1.0/dkms.conf"
  printf 'MAKE[0]="make -C ${kernel_source_dir} M=${dkms_tree}/${PACKAGE_NAME}/${PACKAGE_VERSION}/build modules"\n' \
    >> "$d/dkms/extra-1.0/dkms.conf"
  printf 'obj-m += extra.o\n' > "$d/dkms/extra-1.0/Makefile"; : > "$d/dkms/extra-1.0/extra.c"
  expect_fail "$d" "dkms/extra is shipped but install.sh never installs it" \
    "a module directory the installer never names"

  # 7. MAKE[0] building in a directory the package does not contain: dkms fails
  #    per kernel, inside a log file, worded like a build quirk.
  d=$(mutate make-line-bogus)
  sed -i 's|/build modules|/build/src modules|' "$d/dkms/demo-1.0/dkms.conf"
  expect_fail "$d" "is not in this package" "a MAKE[0] M= path that does not exist in the package"

  # 8. The README's decode table quoting a message the installer does not print.
  #    That table is the user's only key for telling a real install from a no-op,
  #    and it shipped quoting three strings install.sh never produced: you
  #    Ctrl-F the README's wording, find nothing, and cannot tell which row you
  #    are in. Reword the installer and this must fail on the next push.
  d=$(mutate readme-quotes-drifted)
  sed -i 's|this clone/tarball is incomplete, re-download it|this download is incomplete, get it again|' "$d/install.sh"
  expect_fail "$d" "installer output that install.sh never prints" \
    "a README decode table quoting a message the installer does not print"

  # 9. The shipped bug again, reintroduced the way a careful revert would do it:
  #    ONLY the lookup goes back to kernel/<name>/, while a diagnostic counter
  #    elsewhere still globs dkms/<name>-*/. This passed. Two things let it: a
  #    one-path `for ... in X; do ... return 0; done` was read as a candidate
  #    list and exempted, and the per-module check accepted ANY resolving path
  #    in the file -- so the counter answered for the resolver while the
  #    resolver found nothing and install.sh aborted with "this does not look
  #    like the fix-pack directory" at the user's end. Two paths in the dead
  #    list, so the loop is a genuine candidate list and only reading the
  #    resolver's own body can catch it.
  mk_pkg "$t/dead-lookup-live-counter" '"$HERE/kernel/$m" "$HERE/kernel/$m-src"'
  printf 'count_src(){ local m=$1 d n=0; for d in "$HERE"/dkms/"$m"-*/; do [[ -d $d ]] && n=$((n+1)); done; printf "%%s" "$n"; }\n' \
    >> "$t/dead-lookup-live-counter/install.sh"
  expect_fail "$t/dead-lookup-live-counter" "CANNOT FIND module 'demo'" \
    "a dead module lookup vouched for by a diagnostic glob that still resolves"

  # 10. The other direction of the same class: a script that reads a variable
  #     nothing ever assigns. tools/find-ir-node.sh shipped this -- an
  #     `awk -v s="$SD_ENT"` typo killed the subshell under set -u, the script
  #     fell back to a hardcoded CSI-2 port and printed "(auto-detected)" beside
  #     the wrong answer. Teaching the checker to follow `source` must not cost
  #     it this: here the source line is removed and the LD_* reads stay.
  d=$(mutate lib-not-sourced)
  sed -i '/lib-demo/d' "$d/tools/verify.sh"
  expect_fail "$d" "reads unset variable(s)" \
    "a script that reads a library's variables without sourcing the library"

  # 11. A lookup that GREPS CLEAN and still finds nothing. Every search path is
  #     right, every pattern resolves, the pattern harvest is happy -- and one
  #     extra condition in the test means the function returns 1 for every
  #     module. Reading the paths out of the resolver cannot see this; only
  #     running the resolver can. This is why the function is extracted and
  #     called instead of parsed.
  d=$(mutate lookup-greps-clean-finds-nothing)
  sed -i 's|-f $d/dkms.conf ]]|-f $d/dkms.conf \&\& -f $d/Kbuild ]]|' "$d/install.sh"
  expect_fail "$d" "CANNOT FIND module 'demo'" \
    "a module lookup whose paths all resolve but which returns nothing"

  # 12. A fenced transcript of a run that never happened. The old rule --
  #     "shares SOME wording with install.sh" -- passed invented lines on one
  #     borrowed fragment and announced that they shared wording, which is the
  #     README telling the user, with this script's endorsement, to expect
  #     output this program cannot print.
  d=$(mutate readme-invented-transcript)
  printf '\n```\n✓ demo installed and the camera now works\n```\n' >> "$d/README.md"
  expect_fail "$d" "transcript line install.sh never prints" \
    "a fenced transcript quoting a line the installer cannot produce"

  # 13. Case 11 again, with the escape hatch case 11 left open. Break the lookup
  #     the same way AND hand it a local copy of the module name at the call
  #     site, so the resolver is no longer recognised by the shape this script
  #     looks for. That used to drop silently back to the pattern harvest --
  #     which still resolves -- and print a green line per module plus "the
  #     package is internally consistent" for an installer that finds nothing.
  #     Not being able to run the lookup is now the failure it always was: the
  #     question this section exists to answer went unanswered.
  d=$(mutate lookup-hidden-from-the-checker)
  sed -i 's|-f $d/dkms.conf ]]|-f $d/dkms.conf \&\& -f $d/Kbuild ]]|' "$d/install.sh"
  sed -i 's|do find_src "\$m" |do _m=$m; find_src "$_m" |' "$d/install.sh"
  expect_fail "$d" "module lookup was NOT run" \
    "a broken lookup hidden behind a call site this script cannot recognise"

  exit $rc
fi

[[ -f $INSTALL ]] || { printf 'selftest: no install.sh at %s\n' "$INSTALL" >&2; exit 1; }

mapfile -t SCRIPTS < <(find "$ROOT" -path "$ROOT/.git" -prune -o -name 'recovery-extracted' -prune -o -name '*.sh' -type f -print | sort)
mapfile -t DOCS    < <(find "$ROOT" -path "$ROOT/.git" -prune -o -name 'recovery-extracted' -prune -o -name '*.md' -type f -print | sort)

# ===========================================================================
section "install.sh can locate every DKMS module it installs"
# ---------------------------------------------------------------------------
# THE check, and the reason this file exists.
#
# Both halves are read out of install.sh itself -- the module names it iterates
# and the directory patterns it searches -- so this can never drift away from
# the installer. Rewrite install.sh's layout assumption and this fails on the
# next push, which is exactly what did not happen the morning the installer
# shipped searching kernel/<name>/ for modules published as dkms/<name>-<ver>/.

# module names: from `*_MODULES=(a b c)` arrays and from literal `for m in a b c`
mapfile -t REQUIRED_M < <(sed -n 's/^[[:space:]]*REQUIRED_MODULES=(\([^)]*\)).*/\1/p' "$INSTALL" | tr ' ' '\n' | grep -v '^$')
mapfile -t OPTIONAL_M < <(sed -n 's/^[[:space:]]*OPTIONAL_MODULES=(\([^)]*\)).*/\1/p' "$INSTALL" | tr ' ' '\n' | grep -v '^$')
mapfile -t LOOP_M     < <(sed -n 's/^[[:space:]]*for m in \([^;"$]*\);[[:space:]]*do.*/\1/p' "$INSTALL" | tr ' ' '\n' | grep -v '^$')
ALL_M=("${REQUIRED_M[@]}" "${OPTIONAL_M[@]}" "${LOOP_M[@]}")
mapfile -t ALL_M < <(printf '%s\n' "${ALL_M[@]:-}" | grep -v '^$' | sort -u)

# search patterns: every "$HERE/...$m..." path expression in install.sh
MOD_PAT_RE='"?\$HERE"?/[^ ;)]*\$\{?m\}?[^ ;)]*'
mapfile -t MOD_PATTERNS < <(grep -oE "$MOD_PAT_RE" "$INSTALL" | tr -d '"' | sort -u)
# ...and the subset written OUTSIDE a first-match candidate list. Inside one,
# a pattern that resolves for nothing is a harmless fallback; outside one it is
# a path the installer will actually use, so it has to work for every module.
mapfile -t MOD_PAT_PLAIN < <(logical_lines "$INSTALL" | grep '^PLAIN' \
                             | grep -oE "$MOD_PAT_RE" | tr -d '"' | sort -u)

# ---------------------------------------------------------------------------
# ...and, separately, the paths the LOOKUP itself uses.
#
# Checking "some $HERE/...$m... path in install.sh resolves" is not the same
# question as "the installer can find the module", and the difference is not
# academic: revert only find_src's body to the old kernel/<name>/ form and the
# per-module check still passed, because count_src's dkms/<name>-*/ glob -- a
# diagnostic counter that nothing installs from -- resolved and vouched for a
# resolver that no longer used it. A counter must never be able to answer for
# the resolver, so the resolver's own body is read on its own.
#
# The resolver is identified by its CALL SITE, not by its name: the function
# whose success or failure decides whether a module was found --
#     if s=$(find_src "$m"); then ...        find_src "$m" || skip
# -- so renaming it, or replacing it, keeps this honest. `$(count_src "$m")`
# used inside a test is not such a call and is not picked up.
fn_names(){ grep -oE '^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)' "$1" \
            | sed -E 's/^[[:space:]]*(function[[:space:]]+)?//; s/[[:space:]]*\(\)$//' | sort -u; }
fn_body(){ # <script> <fn> -> that function's body (handles one-line definitions)
  awk -v fn="$2" '
    !inb {
      if ($0 ~ "^[[:space:]]*(function[[:space:]]+)?" fn "[[:space:]]*\\(\\)[[:space:]]*\\{") {
        inb=1; rest=$0; sub(/^[^{]*\{/,"",rest); print rest
        if (rest ~ /\}[[:space:]]*$/) inb=0
      }
      next }
    /^[[:space:]]*\}[[:space:]]*$/ { inb=0; next }
    { print }' "$1"
}
RESOLVER_FNS=(); while read -r fn; do
  [[ -n $fn ]] || continue
  grep -qE "(^|[^A-Za-z0-9_])(if[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*=)?[\$]?[(]?${fn}[[:space:]]+\"?[\$]\{?m\}?\"?[)]?[[:space:]]*([;][[:space:]]*then|[|][|]|&&|$)" \
       "$INSTALL" && RESOLVER_FNS+=("$fn")
done < <(fn_names "$INSTALL")
fn_strip(){ # <script> <fn>... -> the script with those function bodies blanked out
  local s=$1; shift
  awk -v fns=" $* " '
    !inb {
      if ($0 ~ /^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)[[:space:]]*\{/) {
        nm=$0; sub(/^[[:space:]]*(function[[:space:]]+)?/,"",nm); sub(/[[:space:]]*\(\).*$/,"",nm)
        if (index(fns," " nm " ")>0) {
          rest=$0; sub(/^[^{]*\{/,"",rest); inb=(rest ~ /\}[[:space:]]*$/)?0:1; print ""; next }
      }
      print; next }
    /^[[:space:]]*\}[[:space:]]*$/ { inb=0; print ""; next }
    { print "" }' "$s"
}
LOOKUP_PATTERNS=(); MOD_PAT_PLAIN_OUT=("${MOD_PAT_PLAIN[@]:-}")
if [[ ${#RESOLVER_FNS[@]} -gt 0 ]]; then
  mapfile -t LOOKUP_PATTERNS < <(for fn in "${RESOLVER_FNS[@]}"; do fn_body "$INSTALL" "$fn"; done \
                                 | grep -oE "$MOD_PAT_RE" | tr -d '"' | sort -u)
  # The same harvest with the lookup's own body removed. Inside a lookup that
  # demonstrably finds every module, a tier that matches nothing is a fallback
  # doing its job -- the published package ships dkms/<name>-<ver>/, so the
  # kernel/<name>/ tier resolves for nothing and must not be reported. Outside
  # it, every one of these paths is used directly. When the lookup is BROKEN
  # nothing about it is exempt: its dead paths are then the whole story.
  mapfile -t MOD_PAT_PLAIN_OUT < <(logical_lines <(fn_strip "$INSTALL" "${RESOLVER_FNS[@]}") \
                                   | grep '^PLAIN' | grep -oE "$MOD_PAT_RE" | tr -d '"' | sort -u)
fi

# ---------------------------------------------------------------------------
# ...and, stronger than either harvest: CALL the lookup.
#
# Reading the paths out of the resolver is still only reading. Add one condition
# to find_src's test -- `&& -f $d/Kbuild` -- and every pattern above still
# resolves, every per-module line above still says PASS, and install.sh finds
# nothing at all. The harvest proves the PATTERN resolves; only running the
# function proves the FUNCTION does, and the function is what ships.
#
# So the resolver is extracted from install.sh BY LINE RANGE into a temp file,
# sourced with HERE set to this package root exactly as install.sh sets it, and
# called once per module. Nothing else in install.sh runs: only the named
# function bodies are copied, and they execute in a separate bash with no
# arguments and no root. The pattern harvest stays as a second, weaker check --
# the two catch different regressions (a broken function that greps clean, and
# a stray path expression the function never touches).
fn_range(){ # <script> <fn> -> "first last" line of that function's definition
  awk -v fn="$2" '
    !inb {
      if ($0 ~ "^[[:space:]]*(function[[:space:]]+)?" fn "[[:space:]]*\\(\\)[[:space:]]*\\{") {
        start=NR; rest=$0; sub(/^[^{]*\{/,"",rest)
        if (rest ~ /\}[[:space:]]*$/) { print start, NR; exit }
        inb=1
      }
      next }
    /^[[:space:]]*\}[[:space:]]*$/ { print start, NR; exit }' "$1"
}

# Which functions to lift out: the resolver, plus every function install.sh
# ASKS about a module -- `$(count_src "$m")` and friends, the ones whose answer
# it consumes rather than the ones that go off and install things -- plus
# anything those call, so the extracted copy is self-contained rather than a
# fragment that fails to source and quietly sends us back to the weak check.
# Deliberately not "everything called with $m": install_module() would drag in
# dkms and half the script, and none of it decides where a module lives.
mapfile -t ALL_FNS < <(fn_names "$INSTALL")
EXTRACT_FNS=()
add_fn(){ local x; for x in "${EXTRACT_FNS[@]:-}"; do [[ $x == "$1" ]] && return 0; done; EXTRACT_FNS+=("$1"); }
for fn in "${RESOLVER_FNS[@]:-}"; do [[ -n $fn ]] && add_fn "$fn"; done
for fn in "${ALL_FNS[@]:-}"; do
  [[ -n $fn ]] || continue
  grep -qE "[\$]\([[:space:]]*${fn}[[:space:]]+\"?[\$]\{?m\}?\"?" "$INSTALL" && add_fn "$fn"
done
CALL_POS='(^|[;&|(]|[[:space:]]&&[[:space:]]|[[:space:]][|][|][[:space:]]|[$][(])[[:space:]]*'
for _ in 1 2 3; do                      # transitive closure, bounded
  before=${#EXTRACT_FNS[@]}
  for fn in "${EXTRACT_FNS[@]:-}"; do
    body=$(fn_body "$INSTALL" "$fn")
    for c in "${ALL_FNS[@]:-}"; do
      [[ -n $c && $c != "$fn" ]] || continue
      grep -qE "$CALL_POS$c([[:space:]]|\$|\))" <<<"$body" && add_fn "$c"
    done
  done
  [[ ${#EXTRACT_FNS[@]} -eq $before ]] && break
done

LOOKUP_LIB=$(mktemp); LOOKUP_RUN=$(mktemp)
trap 'rm -f "$LOOKUP_LIB" "$LOOKUP_RUN"' EXIT   # both are removed below; this
                                                # only covers a death in between
cat > "$LOOKUP_RUN" <<'RUNNER'
#!/usr/bin/env bash
# Run install.sh's own module lookup. $1 = the extracted function bodies,
# $2 = the function, $3 = the module. HERE comes from the environment, which is
# what install.sh sets it to: the package root. 97 = the extract will not
# source, 98 = the function is not defined in it. Neither is "module missing".
HERE=${HERE:?}
. "$1" || exit 97
declare -F "$2" >/dev/null 2>&1 || exit 98
"$2" "$3"
RUNNER
build_lib(){ # <fn>... -> writes $LOOKUP_LIB, non-zero if it will not parse
  local fn r; : > "$LOOKUP_LIB"
  for fn in "$@"; do
    r=$(fn_range "$INSTALL" "$fn"); [[ -n $r ]] || return 1
    sed -n "${r% *},${r#* }p" "$INSTALL" >> "$LOOKUP_LIB"
    printf '\n' >> "$LOOKUP_LIB"
  done
  bash -n "$LOOKUP_LIB" 2>/dev/null
}
call_resolver(){ HERE="$ROOT" bash "$LOOKUP_RUN" "$LOOKUP_LIB" "$1" "$2"; }

# Not being able to RUN the lookup is a failure of this check, not a footnote
# on it. It used to WARN and carry on with the pattern harvest, and a mutant
# showed what that buys: rename the resolver's argument at both call sites so
# this file no longer recognises which function locates a module, break the
# lookup in the same edit, and selftest printed five green module lines and
# "PASS -- the package is internally consistent" for an installer that would
# find nothing at all. The harvest cannot answer this question; when it is the
# only thing left, the honest report is that the question went unanswered.
FN_CALLABLE=0 FN_WHYNOT=""
if [[ ${#RESOLVER_FNS[@]} -gt 0 && ${#ALL_M[@]} -gt 0 ]]; then
  if build_lib "${EXTRACT_FNS[@]}" || build_lib "${RESOLVER_FNS[@]}"; then
    call_resolver "${RESOLVER_FNS[0]}" "${ALL_M[0]}" >/dev/null 2>&1
    case $? in
      97) FN_WHYNOT="install.sh's ${RESOLVER_FNS[0]}() cannot be extracted and run (the copy will not parse)" ;;
      98) FN_WHYNOT="install.sh's ${RESOLVER_FNS[0]}() was not defined by its own extracted body" ;;
      *)  FN_CALLABLE=1 ;;
    esac
  else
    FN_WHYNOT="cannot lift install.sh's module lookup out of the file to run it"
  fi
fi

mod_expand(){ local e=${1//\$HERE/$ROOT}; e=${e//\$\{m\}/$2}; printf '%s' "${e//\$m/$2}"; }
mod_hit(){ # <pattern> <module> -> prints the source dir it resolves to, or fails
  local e d; e=$(mod_expand "$1" "$2")
  for d in $e; do d=${d%/}; d=${d%/.}
    [[ -d $d && -f $d/dkms.conf ]] && { printf '%s' "$d"; return 0; }
  done
  return 1
}

if [[ ${#ALL_M[@]} -eq 0 ]]; then
  fail "cannot determine which modules install.sh installs" \
       "expected REQUIRED_MODULES=(...) or a literal 'for m in ...; do'" \
       "an unknowable module list is an unverifiable installer"
elif [[ ${#MOD_PATTERNS[@]} -eq 0 ]]; then
  fail "install.sh contains no \$HERE/...\$m path — cannot tell where it looks for modules" \
       "if it looks in the wrong place every module is skipped and the run still exits 0"
else
  # Ask the resolver's own paths when they can be read. Falling back to every
  # $HERE/...$m... path in the file is the weaker question -- it is the one that
  # let a dead lookup pass -- so say so out loud rather than answering it
  # silently.
  if [[ ${#LOOKUP_PATTERNS[@]} -gt 0 ]]; then
    SEARCH_PATS=("${LOOKUP_PATTERNS[@]}")
    info "module lookup ${RESOLVER_FNS[*]}() searches: ${SEARCH_PATS[*]}"
    [[ $FN_CALLABLE -eq 1 ]] && \
      info "and ${RESOLVER_FNS[*]}() itself is being RUN, from ${EXTRACT_FNS[*]}() lifted out of install.sh"
  else
    SEARCH_PATS=("${MOD_PATTERNS[@]}")
    if [[ ${#RESOLVER_FNS[@]} -eq 0 ]]; then
      FN_WHYNOT="cannot tell which function install.sh uses to locate a module — expected a call whose success decides it: 'if s=\$(fn \"\$m\"); then' or 'fn \"\$m\" || skip'"
    else
      warn "install.sh's module lookup ${RESOLVER_FNS[*]}() builds no \$HERE/...\$m path this check can read" \
           "checking every \$HERE/...\$m path in the file instead — weaker: a diagnostic glob can vouch for a broken lookup"
    fi
    info "installer searches: ${SEARCH_PATS[*]}"
  fi
  # The one question this section exists to answer is "can install.sh find the
  # module", and only install.sh's own lookup can answer it. If that lookup did
  # not run, the answer is unknown -- and unknown is not a pass.
  if [[ $FN_CALLABLE -eq 0 ]]; then
    fail "install.sh's own module lookup was NOT run — this check did not verify that the installer can find anything" \
         "${FN_WHYNOT:-the lookup could not be identified or lifted out of install.sh}" \
         "the \$HERE/...\$m patterns were read instead, and a pattern that resolves cannot vouch for a function that does not" \
         "restore a lookup this file can identify and run, or teach it the new shape — leaving the question unanswered is not a pass"
  fi
  LOOKUP_BROKEN=0
  for m in "${ALL_M[@]}"; do
    # (a) the weaker question, kept: do the harvested patterns resolve?
    found=""; tried=()
    for pat in "${SEARCH_PATS[@]}"; do
      tried+=("$(rel "$(mod_expand "$pat" "$m")")")
      found=$(mod_hit "$pat" "$m") && break
      found=""
    done
    optional=0
    for o in "${OPTIONAL_M[@]:-}"; do [[ $o == "$m" ]] && optional=1; done
    unshipped=0
    [[ -z $(ls -d "$ROOT"/dkms/"$m"* "$ROOT"/kernel/"$m"* 2>/dev/null) ]] && unshipped=1

    # (b) the real question: hand the module to install.sh's own resolver and
    #     see what it says. Returning 0 is not enough -- it has to hand back a
    #     directory that actually holds a dkms.conf, because that is the path
    #     install.sh goes on to copy and `dkms add`.
    fn_found=""; fn_why=""
    if [[ $FN_CALLABLE -eq 1 ]]; then
      for fn in "${RESOLVER_FNS[@]}"; do
        out=$(call_resolver "$fn" "$m" 2>/dev/null); e=$?
        if [[ $e -ne 0 ]]; then
          fn_why="install.sh's $fn(\"$m\") returned $e — the installer's own lookup finds nothing"
        elif [[ -z $out ]]; then
          fn_why="install.sh's $fn(\"$m\") reported success but printed no path"
        elif [[ ! -d $out ]]; then
          fn_why="install.sh's $fn(\"$m\") returned '$out', which is not a directory"
        elif [[ ! -f $out/dkms.conf ]]; then
          fn_why="install.sh's $fn(\"$m\") returned '$(rel "$out")', which holds no dkms.conf"
        else
          fn_found=$out; continue
        fi
        fn_found=""; break
      done
    fi

    if [[ $FN_CALLABLE -eq 1 && -n $fn_found ]]; then
      pass "$m -> $(rel "$fn_found")/dkms.conf  (install.sh's own ${RESOLVER_FNS[*]}() was run and returned it)"
      [[ -z $found ]] && \
        warn "the pattern harvest no longer resolves '$m', although ${RESOLVER_FNS[*]}() does" \
             "harvested: ${SEARCH_PATS[*]}" \
             "the second, weaker check has drifted and can no longer corroborate the lookup"
    elif [[ $FN_CALLABLE -eq 1 && $optional -eq 1 && $unshipped -eq 1 ]]; then
      warn "optional module '$m' is named by install.sh but not shipped at all" \
           "boards that need it get nothing; install.sh will skip it by design"
    elif [[ $FN_CALLABLE -eq 1 ]]; then
      LOOKUP_BROKEN=1
      shipped=$(cd "$ROOT" && ls -d dkms/"$m"* kernel/"$m"* 2>/dev/null | tr '\n' ' ')
      if [[ -n $found ]]; then
        # The masking shape, named out loud: the glob a reader would check by
        # hand still resolves; the code that ships does not.
        fail "install.sh CANNOT FIND module '$m' — it would skip it and still report success" \
             "$fn_why" \
             "the harvested patterns DO resolve it ($(rel "$found")) — the pattern is fine, the function is not" \
             "shipped:  ${shipped:-(nothing matching)}"
      else
        fail "install.sh CANNOT FIND module '$m' — it would skip it and still report success" \
             "$fn_why" \
             "searched: ${tried[*]}" \
             "shipped:  ${shipped:-(nothing matching)}"
      fi
    elif [[ -n $found ]]; then
      # Not a PASS: the pattern resolved, the function was never asked. Saying
      # PASS here is how a dead lookup gets a green line next to its name.
      warn "$m -> $(rel "$found")/dkms.conf  (by pattern only — install.sh's own lookup was NOT run, so this is unverified)"
    elif [[ $optional -eq 1 && $unshipped -eq 1 ]]; then
      warn "optional module '$m' is named by install.sh but not shipped at all" \
           "boards that need it get nothing; install.sh will skip it by design"
    else
      LOOKUP_BROKEN=1
      shipped=$(cd "$ROOT" && ls -d dkms/"$m"* kernel/"$m"* 2>/dev/null | tr '\n' ' ')
      fail "install.sh CANNOT FIND module '$m' — it would skip it and still report success" \
           "searched: ${tried[*]}" \
           "shipped:  ${shipped:-(nothing matching)}"
    fi
  done

  # Every module path expression written OUTSIDE the candidate list must work
  # for EVERY module the installer names. find_src()'s list may contain a
  # fallback that matches nothing in the published layout -- that is what a
  # fallback is for -- but a path built anywhere else (the copy step, a backup,
  # a dkms add) is used directly, and one wrong layout assumption there skips
  # the module exactly the way the shipped bug did, one function later.
  PLAIN_PATS=("${MOD_PAT_PLAIN_OUT[@]:-}")
  [[ $LOOKUP_BROKEN -eq 1 ]] && PLAIN_PATS=("${MOD_PAT_PLAIN[@]:-}")
  for pat in "${PLAIN_PATS[@]:-}"; do
    [[ -z $pat ]] && continue
    misses=(); for m in "${ALL_M[@]}"; do mod_hit "$pat" "$m" >/dev/null || misses+=("$m"); done
    if [[ ${#misses[@]} -eq ${#ALL_M[@]} ]]; then
      fail "install.sh uses the path '$pat' outside its candidate list, and it resolves for NO module" \
           "expanded for ${ALL_M[0]}: $(rel "$(mod_expand "$pat" "${ALL_M[0]}")")" \
           "this is the shipped bug's shape: the module is looked for where the package does not put it"
    elif [[ ${#misses[@]} -gt 0 ]]; then
      fail "install.sh uses the path '$pat' outside its candidate list; it resolves for ${#ALL_M[@]} modules minus: ${misses[*]}" \
           "that step is skipped for those modules while the rest of the run reports success"
    else
      pass "pattern check: direct path '$pat' resolves for all ${#ALL_M[@]} module(s)"
    fi
  done
fi
rm -f "$LOOKUP_LIB" "$LOOKUP_RUN"

# the reverse: a module in the package that the installer never names is a
# module nobody receives -- the same silent no-op, one level up. This is a
# FAILURE, not a warning: a maintainer adding a sensor driver for one of the
# reporters' boards and forgetting the *_MODULES line ships a package that
# delivers nothing for that board and says Done. If a tree is meant to be inert
# for now, name it in OPTIONAL_MODULES so the intent is recorded in install.sh
# instead of inferred from silence.
for conf in "$ROOT"/dkms/*/dkms.conf; do
  [[ -f $conf ]] || continue
  nm=$(sed -n 's/^PACKAGE_NAME="\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$conf" | head -1)
  known=0
  for m in "${ALL_M[@]:-}"; do [[ $m == "$nm" ]] && known=1; done
  [[ $known -eq 1 ]] || fail "dkms/$nm is shipped but install.sh never installs it" \
                             "installer knows: ${ALL_M[*]:-(none)}" \
                             "add it to REQUIRED_MODULES/OPTIONAL_MODULES in install.sh, or drop the directory"
done

# ===========================================================================
section "dkms.conf is valid and matches the Makefile"
# A dkms.conf that lies about PACKAGE_NAME, or names a module the Makefile does
# not build, fails inside `dkms install` -- whose output install.sh sends to a
# log, so it surfaces as one terse per-kernel warning that reads like a build
# quirk rather than a packaging error.

CLANG_YES=(); CLANG_NO=()
for conf in "$ROOT"/dkms/*/dkms.conf; do
  [[ -f $conf ]] || continue
  d=$(dirname "$conf"); b=$(basename "$d")
  name=$(sed -n 's/^PACKAGE_NAME="\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$conf" | head -1)
  ver=$(sed -n 's/^PACKAGE_VERSION="\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$conf" | head -1)
  mapfile -t built < <(sed -n 's/^BUILT_MODULE_NAME\[[0-9]*\]="\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$conf")

  [[ -n $name ]] || fail "$(rel "$conf"): no PACKAGE_NAME"
  [[ -n $ver  ]] || fail "$(rel "$conf"): no PACKAGE_VERSION"
  [[ ${#built[@]} -gt 0 ]] || fail "$(rel "$conf"): no BUILT_MODULE_NAME — dkms would build and install nothing"
  [[ -n $name && -n $ver && ${#built[@]} -gt 0 ]] && \
    pass "$(rel "$conf"): $name/$ver, builds ${built[*]}"

  # the directory must carry the same version: install.sh copies the tree to
  # /usr/src/<name>-<PACKAGE_VERSION> and dkms reads the conf back from there
  if [[ $b == *-* && -n $ver && -n $name ]]; then
    [[ $b == "$name-$ver" ]] || fail "directory $(rel "$d") does not match $name-$ver from its own dkms.conf" \
        "install.sh installs to /usr/src/$name-$ver — a mismatch is how a stale tree gets built instead"
  fi

  # MAKE[0] is the other half of the build contract, and it is the half that
  # fails per-kernel inside a log file. `M=` names the directory dkms builds in;
  # dkms copies THIS package directory there, so any trailing subpath must exist
  # here too. A stale `M=.../build/src` compiles nothing and reports it once per
  # kernel, worded like a build quirk.
  mkline=$(sed -n 's/^MAKE\[0\]=//p' "$conf" | head -1); mkline=${mkline%\"}; mkline=${mkline#\"}
  mk="$d/Makefile"
  if [[ -z $mkline ]]; then
    warn "$(rel "$conf"): no MAKE[0] — dkms falls back to its own default build command"
  else
    # An intentional exception has to be written down in the dkms.conf, not
    # inferred from a warning nobody reads. `# TOOLCHAIN: <reason>` in the conf
    # is how a tree says "yes, I really do build differently".
    if grep -q 'CC=clang' <<<"$mkline"; then CLANG_YES+=("$b")
    elif grep -qE '^[[:space:]]*#[[:space:]]*TOOLCHAIN:' "$conf"; then
      pass "$(rel "$conf"): builds without CC=clang, and says why in a '# TOOLCHAIN:' comment"
    else CLANG_NO+=("$b"); fi
    grep -qE '[$]\{?kernel_source_dir\}?' <<<"$mkline" \
      || fail "$(rel "$conf"): MAKE[0] never mentions kernel_source_dir" \
              "dkms would build against whatever kernel make picks, not the one being installed for"
    mval=$(grep -oE '(^|[[:space:]])M=[^[:space:]"]+' <<<"$mkline" | head -1); mval=${mval#" "}; mval=${mval#M=}
    if [[ -z $mval ]]; then
      fail "$(rel "$conf"): MAKE[0] has no M= build directory" "$mkline"
    else
      exp=$mval
      exp=${exp//'${dkms_tree}'/@T@};       exp=${exp//'$dkms_tree'/@T@}
      exp=${exp//'${PACKAGE_NAME}'/$name};    exp=${exp//'$PACKAGE_NAME'/$name}
      exp=${exp//'${PACKAGE_VERSION}'/$ver};  exp=${exp//'$PACKAGE_VERSION'/$ver}
      pre="@T@/$name/$ver/build"
      if [[ $exp == "$pre" || $exp == "$pre"/* ]]; then
        sub=${exp#"$pre"}; sub=${sub#/}
        tgt="$d${sub:+/$sub}"
        if [[ -d $tgt ]]; then
          mk="$tgt/Makefile"
          [[ -f $mk ]] || fail "$(rel "$conf"): MAKE[0] builds in M=$mval but $(rel "$tgt") has no Makefile"
          [[ -z $sub ]] || pass "$(rel "$conf"): MAKE[0] builds in $sub/, which the package ships"
        else
          fail "$(rel "$conf"): MAKE[0] builds in M=$mval — '$sub' is not in this package" \
               "dkms runs make in a directory that does not exist and every kernel's build fails in a log"
        fi
      else
        fail "$(rel "$conf"): MAKE[0]'s M=$mval is not the dkms build directory for $name/$ver" \
             "expected \${dkms_tree}/$name/$ver/build[/subdir] — anything else builds a tree dkms did not stage"
      fi
    fi
  fi

  if [[ ! -f $mk ]]; then
    [[ -f $d/Makefile ]] || fail "$(rel "$d"): no Makefile — dkms has nothing to run"
  else
    for idx in "${!built[@]}"; do
      bm="${built[$idx]}"
      bloc=$(sed -n "s/^BUILT_MODULE_LOCATION\[$idx\]=\"\{0,1\}\([^\"]*\)\"\{0,1\}.*/\1/p" "$conf")
      submk="$mk"
      [[ -n $bloc && -f "$d/$bloc/Makefile" ]] && submk="$d/$bloc/Makefile"
      grep -qE "(^|[[:space:]])${bm//./\\.}\.o([[:space:]]|$)" "$submk" \
        || fail "$(rel "$submk") does not build $bm.o, but dkms.conf expects $bm.ko" \
                "dkms fails at its copy step; the user sees one line about one kernel"
      objs=$(sed -n "/^${bm//./\\.}\(-y\|-objs\)[[:space:]]*[+:=[[:space:]]*/{:a; /\\\\$/{N; s/\\\\\n//; ta}; p}" "$submk" \
             | sed "s/^${bm//./\\.}\(-y\|-objs\)[[:space:]]*[+:=[[:space:]]*//")
      [[ -z $objs ]] && objs="$bm.o"
      for o in $objs; do
        [[ -f "${submk%/Makefile}/${o%.o}.c" ]] || fail "$(rel "${submk%/Makefile}"): missing source ${o%.o}.c (needed for $bm)" \
                                        "the module is listed but its code is not in the package"
      done
    done
  fi
done

# These trees are built with clang against clang-built kernels. One conf losing
# CC=clang while its siblings keep it builds that module with a different
# toolchain than the kernel it loads into -- which surfaces as a LOAD failure,
# not a build failure, long after the installer said Done.
#
# This was a warn(). The file's own header says a warning CI ignores is how the
# verify.sh split shipped, and a symptom that appears after "Done" is exactly
# what this suite is for, so it fails. The written-down escape hatch is a
# `# TOOLCHAIN: <reason>` comment in the odd conf (handled above).
if [[ ${#CLANG_YES[@]} -gt 0 && ${#CLANG_NO[@]} -gt 0 ]]; then
  fail "MAKE[0] toolchain is inconsistent: ${CLANG_NO[*]} build without CC=clang, ${CLANG_YES[*]} with it" \
       "the odd one out is compiled by a different toolchain than the kernel it loads into," \
       "which shows up as a LOAD failure long after the installer reported success" \
       "if it really is deliberate, put a '# TOOLCHAIN: <reason>' line in ${CLANG_NO[0]}'s dkms.conf"
elif [[ ${#CLANG_YES[@]} -gt 0 ]]; then
  pass "all ${#CLANG_YES[@]} dkms.conf MAKE[0] lines use the same toolchain (CC=clang)"
fi

# ===========================================================================
section "every path the scripts reference exists in the package"
# References are gathered from the scripts themselves: a script that resolves
# its own directory ($HERE=$(cd "$(dirname "$0")" ...)) has that variable name
# discovered, so new scripts are covered without editing anything here.
#
# Every reference must resolve ON ITS OWN. The single exception is a real
# first-match-wins candidate list -- `for c in A B; do [[ -f $c ]] && break` --
# where the code itself only needs one of the paths; those, and only those, are
# grouped, and the group prints "1 of 2 present" so the tolerance is visible.
#
# This used to group by BASENAME instead, which quietly merged unrelated
# references: install.sh's `$HERE/verify.sh` and the README's `tools/verify.sh`
# became one group, and deleting either file still passed at "1 of 2 candidate
# paths present" while one of the two documented commands no longer existed.

declare -A GRP=()
declare -a REFLOG=()
# add_ref <path> <strict> <group-id> <origin>
#   strict=1  a real code path ($HERE/...): the file must be there, full stop.
#   strict=0  a path named in prose or a comment: required only when its parent
#             directory exists here, so documentation that quotes a path in some
#             OTHER tree (kernel/drivers/staging/..., /usr/lib/howdy/...) does
#             not masquerade as a missing package file.
#   group-id  paths sharing one id satisfy each other (candidate lists only).
#             Everything else uses "path:<p>", so the same path mentioned in ten
#             places is one check and two different paths are two checks.
add_ref(){
  local p=${1#/} strict=$2 gid=$3 origin=${4:-} hit=0 req
  [[ -z $p || $p == . || $p == .. ]] && return 0
  [[ $p == .git* || $p == */.git* ]] && return 0
  [[ $p == ../* || $p == */../* ]] && return 0             # outside the package
  [[ -e $ROOT/$p ]] && hit=1
  req=$strict
  [[ $strict -eq 0 && -d $ROOT/$(dirname "$p") ]] && req=1
  REFLOG+=("$origin|$(basename "$p")|$p|$hit")
  case " ${GRP[$gid]:-} " in *" $p|"*) return 0;; esac      # same path, said twice
  GRP[$gid]="${GRP[$gid]:-} $p|$hit|$req"
}
sane_token(){ [[ -n $1 && $1 != *'$'* && $1 != *'*'* && $1 != *'{'* && $1 != *'}'* && $1 != *'<'* && $1 != *'('* ]]; }

KNOWN_TOP='tools|udev|howdy|dkms|kernel|scripts|docs|ipu7poke|usbio-patch'

for s in "${SCRIPTS[@]}"; do
  rs=$(rel "$s")
  # a variable is this script's own root only if it is assigned from $0 / BASH_SOURCE
  mapfile -t rootvars < <(grep -E '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=.*dirname.*(\$0|BASH_SOURCE)' "$s" \
                          | sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=.*/\1/' | sort -u)
  rootvars+=(HERE)
  ln=0
  while IFS=$'\t' read -r tag line; do
    ln=$((ln+1))
    toks=()
    for v in "${rootvars[@]}"; do
      while read -r tok; do
        tok=$(printf '%s' "$tok" | tr -d '"'"'")
        tok=${tok#\$\{$v\}/}; tok=${tok#\$$v/}
        tok=${tok%%[),\`]*}
        sane_token "$tok" && toks+=("$tok")
      done < <(grep -oE "\"?\\\$\{?$v\}?\"?/[^ ;)\`]*" <<<"$line")
    done
    # $(dirname ...)/x is only a PACKAGE path when the dirname is of this
    # script itself. `$(dirname "$HOWDY_BIN")/recorders` is a path on the user's
    # machine, and demanding the package ship a "recorders" file is a false
    # accusation of the kind this whole package exists to stop making.
    while read -r tok; do
      tok=${tok#*)/}; tok=$(printf '%s' "$tok" | tr -d '"'"'")
      sane_token "$tok" && toks+=("$tok")
    done < <(grep -oE '\$\(dirname[^)]*(\$0|BASH_SOURCE)[^)]*\)/[A-Za-z0-9_./-]+' <<<"$line")
    [[ ${#toks[@]} -eq 0 ]] && continue
    if [[ $tag == CAND && ${#toks[@]} -gt 1 ]]; then
      for t in "${toks[@]}"; do add_ref "$t" 1 "cand:$rs:$ln" "$rs"; done
    else
      for t in "${toks[@]}"; do add_ref "$t" 1 "path:$t" "$rs"; done
    fi
  done < <(logical_lines "$s")
done

# Paths named in scripts, comments and docs: repo-relative ("run tools/verify.sh")
# and root-level ("sudo ./install.sh"). The root-level form used to be invisible
# here -- the pattern only knew the subdirectory names -- so the README's own
# entry point, the thing every stranger types first, was the one path nothing
# checked. A quick-start block naming a script that was never committed passed.
for f in "${SCRIPTS[@]}" "${DOCS[@]}"; do
  rf=$(rel "$f"); fdir=$(dirname "$rf"); [[ $fdir == . ]] && fdir=""
  # This file is the checker, not documentation: its comments quote paths and
  # commands as EVIDENCE (the fixtures --prove builds, the scripts whose past
  # bugs each check exists for). Treating those as instructions to the user
  # would make every explanation a maintenance burden.
  [[ $f == "${BASH_SOURCE[0]}" || $rf == tools/selftest.sh ]] && continue
  while read -r kind tok; do
    tok=${tok%%[\`,\"\']*}; tok=${tok%.}; tok=${tok%:}
    sane_token "$tok" || continue
    [[ $tok == */ && -d $ROOT/${tok%/} ]] && continue    # bare directory in prose
    # prose that merely reads like a path -- "a kernel/udev concern" -- is not a
    # reference. Require a filename (something.ext) unless the path is real.
    [[ ${tok##*/} == *.* || -e $ROOT/$tok ]] || continue
    if [[ $kind == DOT && $tok != */* && -n $fdir ]]; then
      # a bare dot-slash command in a file that lives in a subdirectory is
      # ambiguous: a script's own usage line means "beside me", a README-style
      # quick start means "from the repo root". Either resolving is enough;
      # neither resolving is a documented command that cannot be typed.
      add_ref "$fdir/$tok" 0 "dot:$rf:$tok" "$rf"
      add_ref "$tok"       0 "dot:$rf:$tok" "$rf"
    else
      add_ref "$tok" 0 "path:$tok" "$rf"
    fi
  done < <( { grep -hoE "(^|[^A-Za-z0-9_/.\$-])($KNOWN_TOP)/[A-Za-z0-9_./-]+" "$f" | sed -E 's@^[^A-Za-z]*@@; s@^@REL @'
              grep -hoE "(^|[^A-Za-z0-9_/-])\./[A-Za-z0-9_./-]+\.(sh|py)" "$f" | sed -E 's@^[^.]*\./@@; s@^@DOT @'
            } )
done

while read -r gid; do
  present=0; total=0; required=0; detail=""; miss=""
  for e in ${GRP[$gid]}; do
    total=$((total+1))
    IFS='|' read -r epath ehit ereq <<<"$e"
    [[ $ereq == 1 ]] && required=1
    if [[ $ehit == 1 ]]; then present=$((present+1)); detail=$epath; else miss+=" $epath"; fi
  done
  if [[ $present -gt 0 ]]; then
    if [[ $total -gt 1 ]]; then pass "$detail  ($present of $total candidate paths present)"
    else pass "$detail"; fi
  elif [[ $required -eq 1 ]]; then
    fail "referenced but MISSING from the package:$miss" \
         "a script or doc points at a file that is not here; whatever uses it gets skipped"
  fi
done < <(printf '%s\n' "${!GRP[@]}" | sort)

# install.sh's last screen and the README must send the user to the SAME file.
# They did not: install.sh said `sudo $HERE/verify.sh`, the README said
# `sudo ./tools/verify.sh`, and the two were 37 lines apart -- the installer
# recommending the copy that could not detect the failure it had just warned
# about. Comparing resolved paths (so a symlink counts as the same file) makes
# that divergence impossible to ship again.
declare -A IREF=() RREF=()
for r in "${REFLOG[@]}"; do
  IFS='|' read -r org rb rp rhit <<<"$r"
  [[ $rhit == 1 ]] || continue
  real=$(readlink -f "$ROOT/$rp")
  case $org in
    install.sh) IREF[$rb]="${IREF[$rb]:-} $real" ;;
    README.md)  RREF[$rb]="${RREF[$rb]:-} $real" ;;
  esac
done
while read -r rb; do
  [[ -z $rb || -z ${RREF[$rb]:-} ]] && continue
  # They agree if some file is named by both. install.sh listing two candidates
  # for one file is fine; naming a DIFFERENT file than the README is not.
  common=""
  for x in ${IREF[$rb]}; do
    for y in ${RREF[$rb]}; do [[ $x == "$y" ]] && common=$x; done
  done
  if [[ -z $common ]]; then
    mapfile -t u < <(printf '%s\n' ${IREF[$rb]} ${RREF[$rb]} | sort -u)
    fail "install.sh and README.md point at DIFFERENT files named $rb" \
         "install.sh: $(for x in ${IREF[$rb]}; do printf '%s ' "$(rel "$x")"; done)" \
         "README.md:  $(for x in ${RREF[$rb]}; do printf '%s ' "$(rel "$x")"; done)" \
         "one of the two instructions is the stale one and the user cannot tell which"
  else
    pass "install.sh and README.md agree on $rb -> $(rel "$common")"
  fi
done < <(printf '%s\n' "${!IREF[@]}" | sort)

# The check above is keyed by BASENAME, so it can only compare tools both files
# happen to name. Point install.sh's last screen at a DIFFERENT tool that also
# exists -- `sudo $HERE/tools/find-ir-node.sh   check the whole stack` -- and
# verify.sh simply drops out of IREF, the loop never compares it, and nothing
# else notices because the file it now names is really there. That is the same
# divergence one step further along, and it passed.
#
# So compare the two INSTRUCTIONS directly: every tools/*.sh the README's
# Verification section tells a user to run after the reboot must also be named
# in install.sh's own "After rebooting:" block. The installer is the last thing
# on screen; if it sends people somewhere the README does not, the README is
# not the documentation of this installer.
# Anchor on `say "Done"`, not on "After rebooting:": usage()'s footer contains
# that phrase too, near the top of the file, so scanning from there swept in the
# whole script and the mutation stayed green.
IS_NEXT=$(awk '/^say "Done"/ || /==> Done/ {f=1} f' "$INSTALL" | grep -oE '[^ "]*tools/[A-Za-z0-9_-]+\.sh' | sed 's|.*tools/|tools/|' | sort -u)
RM_VERIFY=$(awk '/^## Verification/{f=1;next} /^## /{f=0} f' "$README" | grep -oE '\./tools/[A-Za-z0-9_-]+\.sh' | sed 's|^\./||' | sort -u)
if [[ -z $RM_VERIFY ]]; then
  warn "the README's Verification section names no tools/*.sh to run" \
       "if verification has moved, this check no longer guards anything"
else
  vmiss=""
  while read -r v; do
    [[ -n $v ]] || continue
    grep -qxF "$v" <<<"$IS_NEXT" || vmiss="$vmiss $v"
  done <<<"$RM_VERIFY"
  if [[ -n $vmiss ]]; then
    fail "install.sh's 'After rebooting:' block never names:$vmiss" \
         "the README tells people to run it after this exact install, and the" \
         "installer's own last screen sends them somewhere else" \
         "install.sh names: $(tr '\n' ' ' <<<"$IS_NEXT")"
  else
    pass "install.sh's last screen names every verification tool the README does ($(tr '\n' ' ' <<<"$RM_VERIFY"))"
  fi
fi

# ===========================================================================
section "installer assets install.sh copies verbatim"
# Payload, not code. If one is absent the installer skips a whole feature --
# illuminator permissions, the Howdy recorder -- and the user ends up with a
# camera that streams and an authentication that never works.
for want in udev/99-hm1092-ir-led.rules howdy/ir_reader.py howdy/video_capture.patch; do
  if [[ -e $ROOT/$want ]]; then
    grep -q "$(basename "$want")" "$INSTALL" \
      && pass "$want present and referenced by install.sh" \
      || warn "$want is in the package but install.sh never mentions it"
  else
    fail "$want MISSING — install.sh installs this file"
  fi
done

# the patch and the recorder are a contract: the patch imports a name that must
# exist in the recorder shipped beside it
if [[ -f $ROOT/howdy/video_capture.patch && -f $ROOT/howdy/ir_reader.py ]]; then
  while read -r sym; do
    [[ -z $sym ]] && continue
    grep -qE "^(class|def) ${sym}\b" "$ROOT/howdy/ir_reader.py" \
      && pass "video_capture.patch imports '$sym' and ir_reader.py defines it" \
      || fail "video_capture.patch imports '$sym', howdy/ir_reader.py does not define it" \
              "Howdy raises ImportError during authentication, inside a PAM stack, where nobody sees it"
  done < <(grep -oE 'from recorders\.ir_reader import [A-Za-z_][A-Za-z0-9_]*' "$ROOT/howdy/video_capture.patch" \
           | awk '{print $NF}' | sort -u)
fi

# ===========================================================================
section "scripts are runnable"
for s in "${SCRIPTS[@]}"; do
  r=$(rel "$s"); ok=1
  head -1 "$s" | grep -q '^#!' || { fail "$r: no shebang"; ok=0; }
  sh_bin=bash; head -1 "$s" | grep -qE '^#!.*/(da|a)?sh$' && sh_bin=sh
  if ! err=$("$sh_bin" -n "$s" 2>&1); then
    fail "$r: syntax error ($sh_bin -n)" "$err"; ok=0
  fi
  [[ -x $s ]] || { fail "$r: not executable" "documented as './$r' — a stranger gets 'Permission denied'"; ok=0; }
  if git -C "$ROOT" rev-parse >/dev/null 2>&1 && git -C "$ROOT" ls-files --error-unmatch "$s" >/dev/null 2>&1; then
    mode=$(git -C "$ROOT" ls-files -s -- "$s" | awk '{print $1}')
    [[ $mode == 100755 ]] || {
      fail "$r: git mode $mode, not 100755" \
           "the exec bit is local to this working tree; every clone and tarball gets a non-executable script"; ok=0; }
  fi
  [[ $ok -eq 1 ]] && pass "$r: shebang, $sh_bin -n clean, executable, mode 100755"
done

if command -v python3 >/dev/null 2>&1; then
  while read -r py; do
    if err=$(python3 -m py_compile "$py" 2>&1); then pass "$(rel "$py"): compiles"
    else fail "$(rel "$py"): python syntax error" "$err"; fi
  done < <(find "$ROOT" -path "$ROOT/.git" -prune -o -name 'recovery-extracted' -prune -o -name '*.py' -type f -print | sort)
  find "$ROOT" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null
else
  warn "python3 not available — skipped the syntax check of the Howdy recorder"
fi

# ===========================================================================
section "no script dies on an unset variable"
# Under `set -u` a variable that is read but never assigned aborts the script at
# that line. It presents as "the tool printed two lines and stopped", with no
# error the user can connect to a typo. tools/find-ir-node.sh did exactly this:
# an `awk -v s="$SD_ENT"` typo killed the subshell, the script fell back to a
# hardcoded CSI-2 port, and printed "(auto-detected)" next to the wrong answer.
#
# ShellCheck cannot cover this: SC2154 deliberately ignores ALL-CAPS names,
# assuming they come from the environment, and these are all ALL-CAPS.
AWK_BUILTINS=' NF NR FS OFS ORS RS FILENAME FNR SUBSEP RSTART RLENGTH CONVFMT OFMT ENVIRON '
SHELL_ENV=' HOME PATH USER LOGNAME EUID UID PWD OLDPWD IFS SHELL TERM LANG LC_ALL HOSTNAME
 RANDOM SECONDS LINENO BASH BASH_SOURCE BASH_VERSION BASH_REMATCH FUNCNAME PIPESTATUS REPLY
 OPTARG OPTIND CDPATH TMPDIR SUDO_USER SUDO_UID DISPLAY XDG_RUNTIME_DIR EDITOR NO_COLOR
 KERNELRELEASE KERNEL_SRC KVER KBUILD MAKE CC LD DESTDIR
 dkms_tree kernel_source_dir PACKAGE_NAME PACKAGE_VERSION '
# A script that SOURCES another file in this package inherits its variables, so
# reading one of them is not an unset read. verify.sh and find-ir-node.sh get
# every LD_* name from tools/lib-detect.sh this way, and install.sh gets the
# HW_* names from tools/check-hardware.sh. Without this the check would demand
# that a library's callers redeclare its interface -- a false failure, which is
# how a useful check gets deleted: a red CI on a correct refactor gets the check
# weakened or the shared library abandoned, and then the duplicated detection
# logic drifts apart again.
#
# Sourcing is followed TRANSITIVELY -- a library may itself source another --
# and only for files that resolve inside this package: `. /etc/os-release` says
# nothing this check may rely on. A seen-set makes a cycle (two libraries that
# source each other, or a library that sources its caller) terminate instead of
# hanging, which is the failure mode that would otherwise take out CI.
source_refs(){ # <script> -> package files it sources DIRECTLY, resolved
  local sd; sd=$(dirname "$1")
  sed 's/^[[:space:]]*#.*//' "$1" \
    | grep -oE '(^|[[:space:]]|;)(\.|source)[[:space:]]+[^[:space:];&|<>)]+' \
    | sed -E 's/^[[:space:]]*;?[[:space:]]*(\.|source)[[:space:]]+//' \
    | tr -d '"'"'"'' \
    | while read -r p; do
        [[ -n $p ]] || continue
        # strip a leading $VAR/ or $(dirname "$0")/ so the tail is package-relative
        p=$(printf '%s' "$p" | sed -E 's@^\$\([^)]*\)/@@; s@^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/@@; s@^\./@@')
        local c
        for c in "$ROOT/$p" "$sd/$p"; do
          [[ -f $c ]] && { readlink -f "$c"; break; }
        done
      done
}
sourced_files(){ # <script> -> every package file it sources, transitively
  local -A seen=(); local -a queue=(); local cur p
  seen[$(readlink -f "$1")]=1; queue=("$1")
  while [[ ${#queue[@]} -gt 0 ]]; do
    cur=${queue[0]}; queue=("${queue[@]:1}")
    while read -r p; do
      [[ -n $p && -z ${seen[$p]:-} ]] || continue   # already followed: cycle guard
      seen[$p]=1; printf '%s\n' "$p"; queue+=("$p")
    done < <(source_refs "$cur")
  done
}

CODE=$(mktemp); CODEA=$(mktemp); trap 'rm -f "$CODE" "$CODEA"' EXIT
for s in "${SCRIPTS[@]}"; do
  grep -qE '^[[:space:]]*set[[:space:]]+-[a-z]*u|set -o nounset' "$s" || continue
  # Blank out whole-line comments, keeping the line count so reported line
  # numbers still match the real file. Prose about a variable is not a use of
  # it -- and this file's own comments discuss the very typos it hunts for.
  sed 's/^[[:space:]]*#.*//' "$s" > "$CODE"
  # $CODE  = this script alone, for the USES and the line numbers.
  # $CODEA = this script plus whatever it sources, for the ASSIGNMENTS.
  cp "$CODE" "$CODEA"; inherited=""
  while read -r sf; do
    [[ -n $sf ]] || continue
    sed 's/^[[:space:]]*#.*//' "$sf" >> "$CODEA"
    inherited+=" $(rel "$sf")"
  done < <(sourced_files "$s")
  assigned=" $( {
      # NAME=, export/local/declare/readonly NAME=, NAME[key]=, NAME+=(
      grep -oE '(^|[[:space:]]|;|&|\|)(export|local|readonly|declare|typeset)?[[:space:]]*[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=' "$CODEA" \
        | grep -oE '[A-Za-z_][A-Za-z0-9_]*(\[|\+?=)' | sed -E 's/(\[|\+?=)$//'
      # bare declarations: local a b c / declare -A x
      grep -oE '(^|[[:space:]])(local|declare|typeset|readonly)([[:space:]]+-[a-zA-Z]+)*[[:space:]]+[A-Za-z0-9_ ]+' "$CODEA" \
        | sed -E 's/.*(local|declare|typeset|readonly)([[:space:]]+-[a-zA-Z]+)*[[:space:]]+//' | tr ' ' '\n'
      grep -oE '(^|[;&|][[:space:]]*|[[:space:]])for[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' "$CODEA" | awk '{print $NF}'
      # read [-flags] a b c  -- every name, not just the first
      grep -oE '(^|[[:space:]|;])read[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*[A-Za-z_][A-Za-z0-9_ ]*' "$CODEA" \
        | sed -E 's/.*read[[:space:]]+//; s/(-[a-zA-Z]+[[:space:]]+)*//' | tr ' ' '\n'
      grep -oE 'mapfile[^|<]*[[:space:]][A-Za-z_][A-Za-z0-9_]*' "$CODEA" | awk '{print $NF}'
      grep -oE 'printf[[:space:]]+-v[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' "$CODEA" | awk '{print $NF}'
      grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*:?=' "$CODEA" | tr -d '${:='
      # function parameters are positional, never named
    } | sort -u | tr '\n' ' ' ) "
  bad=""; lines=""
  while read -r v; do
    [[ -z $v ]] && continue
    [[ $assigned    == *" $v "* ]] && continue
    [[ $AWK_BUILTINS == *" $v "* ]] && continue
    [[ $SHELL_ENV    == *" $v "* ]] && continue
    total=$(grep -oE "\\\$\{?$v([^A-Za-z0-9_]|$)" "$CODE" | wc -l)
    prot=$(grep -oE "\\\$\{$v:?[-+=?]" "$CODE" | wc -l)
    [[ $total -le $prot ]] && continue         # every use has a default -- safe
    bad+=" $v"
    lines+="$(grep -nE "\\\$\{?$v([^A-Za-z0-9_]|$)" "$CODE" | grep -vE "\\\$\{$v:?[-+=?]" | head -1)"$'\n'
  done < <(grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*' "$CODE" | tr -d '${' | sort -u)
  if [[ -n $bad ]]; then
    fail "$(rel "$s"): reads unset variable(s):$bad — under 'set -u' the script aborts there" "${lines%$'\n'}"
  else
    pass "$(rel "$s"): no unset-variable exit${inherited:+ (inherits:$inherited)}"
  fi
done

# ===========================================================================
section "README and install.sh agree"
kern_ranges(){ grep -ohE '[0-9]+\.[0-9]+(\.[0-9]+)?(-rc[0-9]+)?[[:space:]]+(through|to)[[:space:]]+[0-9]+\.[0-9]+(\.[0-9]+)?(-rc[0-9]+)?' "$1" \
               | sed -E 's/[[:space:]]+(through|to)[[:space:]]+/../' | sort -u; }
i_range=$(kern_ranges "$INSTALL"); r_range=$(kern_ranges "$README")
if [[ -z $i_range && -z $r_range ]]; then
  warn "neither README nor install.sh states a supported kernel range" \
       "a stranger cannot tell whether their kernel is in scope"
elif [[ -z $i_range ]]; then
  warn "README claims kernels $(tr '\n' ' ' <<<"$r_range")but install.sh's header states no range"
elif [[ -z $r_range ]]; then
  fail "install.sh claims kernels $i_range but the README states no range"
elif grep -qxF "$i_range" <<<"$r_range"; then
  pass "supported kernels agree: $i_range"
else
  fail "README and install.sh disagree about supported kernels" \
       "install.sh: $(tr '\n' ' ' <<<"$i_range")" \
       "README:     $(tr '\n' ' ' <<<"$r_range")"
fi

# The README's recovery block must name the modules and versions the installer
# actually creates. A `dkms remove` for a version that is not the shipped one
# prints nothing and removes nothing -- a user backing out a broken install is
# told it worked while every module stays exactly where it was.
if grep -q 'dkms remove' "$README"; then
  # names: literal `-m NAME`, plus a `for m in a b c` loop feeding `-m $m`
  covered=" $( { grep -oE 'dkms remove -m [A-Za-z0-9_-]+' "$README" | awk '{print $NF}'
                 grep -q 'dkms remove -m \$m' "$README" && \
                   sed -n 's/^[[:space:]]*for m in \([^;]*\);[[:space:]]*do.*/\1/p' "$README" | tr ' ' '\n'
               } | grep -v '^\$' | sort -u | tr '\n' ' ') "
  for m in "${ALL_M[@]:-}"; do
    [[ -z $m ]] && continue
    if [[ $covered != *" $m "* ]]; then
      warn "install.sh installs '$m' but the README recovery block never removes it" \
           "a user backing the pack out is left with $m still installed"
      continue
    fi
    conf=$(ls -d "$ROOT"/dkms/"$m"-*/dkms.conf "$ROOT"/dkms/"$m"/dkms.conf 2>/dev/null | head -1)
    [[ -n $conf ]] || continue
    real=$(sed -n 's/^PACKAGE_VERSION="\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$conf" | head -1)
    docver=$(grep -oE "dkms remove -m (\\\$m|$m) -v [0-9][^ ]*" "$README" | awk '{print $NF}' | sort -u | head -1)
    srcver=$(grep -oE "/usr/src/$m-[0-9][A-Za-z0-9._-]*" "$README" | sed "s|.*/$m-||" | sort -u | head -1)
    okver=1
    for dv in $docver $srcver; do
      [[ $dv == "$real" ]] || { fail "README recovery uses $m version '$dv' but the package ships $m/$real" \
                                     "that dkms remove / rm -rf matches nothing and reports nothing"; okver=0; }
    done
    [[ $okver -eq 1 ]] && pass "README recovery covers $m at the shipped version ($real)"
  done
else
  warn "README has no 'dkms remove' recovery block" \
       "a stranger who breaks their camera has no documented way back"
fi

# ===========================================================================
section "the README quotes the installer's REAL output"
# The README's "what to expect" table is the only key a user has for telling a
# real install from a no-op, and it used to quote three lines install.sh never
# prints -- e.g. "! <module> not found in package (looked in dkms/ and kernel/)"
# against an installer that actually says "package is missing module 'hm1092'
# ... this clone/tarball is incomplete, re-download it". Ctrl-F finds nothing
# and the reader cannot tell which row of the table they are in.
#
# Every README string that starts with one of the installer's own glyphs is
# checked here. <placeholders> are cut out, and each remaining literal run has
# to appear verbatim in install.sh. Reword a message and this fails on the next
# push, which is the only thing that keeps a decode table honest.
#
# Two kinds of quotation, held to two standards:
#   TPL    — a backtick-quoted message TEMPLATE, i.e. a row of the decode table.
#            Every literal run between <placeholders> must be in install.sh.
#            This is the one that shipped wrong, so a mismatch is a FAIL.
#   SAMPLE — a line inside a fenced transcript. It carries one machine's real
#            kernel and module names, so it cannot match verbatim -- but it is
#            still an INSTANCE of a message install.sh prints. Mask the
#            machine-specific words and every literal run that remains must be
#            in install.sh, exactly as for a table row. A mismatch is a FAIL.
#
# "Shares SOME wording with install.sh" was the old standard and it endorsed
# fabrications: `✓ Secure Boot is fine, nothing more to do`, `✓ dkms build
# succeeded for every kernel on this machine` and `✓ modules installed : 7 / 5
# and the camera now works` all PASSED, each on the strength of one borrowed
# fragment, and the check said they "share wording with install.sh". A fenced
# transcript is a promise about what this program prints; a check that endorses
# an invented one is worse than no check, because the reader then trusts it.
sq(){ tr -s ' \t' ' ' ; }                       # whitespace-insensitive compare
# The machine-specific words of a transcript line -- module names, kernel
# versions, paths, counts, .ko files -- are exactly the ones install.sh cannot
# contain literally, so they are masked out and everything else is held to the
# installer's own wording.
sample_runs(){ # <bare sample> -> its literal runs, one per line
  local s run="" cur w; local -a W=()
  s=$(printf '%s' "$1" | sed 's/<[^>]*>/ @@VAR@@ /g')
  read -ra W <<<"$s"
  for w in "${W[@]}"; do
    cur=${w//[[:punct:]]/}
    if [[ $w == @@VAR@@ || $w == */* || $w == *.ko || $w =~ [0-9] || " ${ALL_M[*]:-} " == *" $cur "* ]]; then
      [[ -n $run ]] && printf '%s\n' "$run"
      run=""
    else
      run="${run:+$run }$w"
    fi
  done
  [[ -n $run ]] && printf '%s\n' "$run"
  return 0
}
INSTALL_SQ=$(mktemp); sq < "$INSTALL" > "$INSTALL_SQ"
n_quoted=0
while IFS='|' read -r kind q; do
  [[ -z ${q:-} ]] && continue
  n_quoted=$((n_quoted+1))
  bare=$(printf '%s' "$q" | sed -E 's/^[[:space:]]*(✓|✗|!|·)[[:space:]]+//')
  short=$(printf '%s' "$q" | cut -c1-58)
  if [[ $kind == TPL ]]; then
    missing=(); checked=0
    while IFS= read -r seg; do
      seg=$(printf '%s' "$seg" | sq); seg=${seg#" "}; seg=${seg%" "}
      [[ ${#seg} -ge 8 ]] || continue
      checked=$((checked+1))
      grep -qF -- "$seg" "$INSTALL_SQ" || missing+=("$seg")
      # printf '%s\n', not '%s': without the trailing newline `read` returns
      # non-zero on the final segment and the loop body never runs for it. Every
      # quote made of ONE literal run -- which is every exact message in the
      # table -- then scored checked=0 and was reported as "all placeholders,
      # nothing to check". The drift check that exists to keep the README honest
      # was checking nothing, and saying so as a warning.
    done < <(printf '%s\n' "$bare" | sed -E 's/<[^>]*>/\n/g')
    if [[ $checked -eq 0 ]]; then
      warn "README quotes '$short' but every part of it is a <placeholder>" \
           "nothing in that row can be checked against install.sh, so it can drift freely"
    elif [[ ${#missing[@]} -gt 0 ]]; then
      fail "README quotes installer output that install.sh never prints: '$q'" \
           "not found in install.sh: $(printf "'%s' " "${missing[@]}")" \
           "a reader who Ctrl-Fs the README's wording finds nothing and cannot tell which case they are in"
    else
      pass "README's '$short' matches install.sh"
    fi
  else
    mapfile -t runs < <(sample_runs "$bare")
    matched=(); missing=(); checked=0
    for r in "${runs[@]:-}"; do
      r=$(printf '%s' "$r" | sq); r=${r#" "}; r=${r%" "}
      [[ ${#r} -ge 5 ]] || continue           # ")" or "->" proves nothing either way
      checked=$((checked+1))
      if grep -qF -- "$r" "$INSTALL_SQ"; then matched+=("$r"); continue; fi
      # A label the installer builds from a variable ("modules installed" + " :")
      # is the installer's wording even though the punctuation around it is not,
      # so a run is given one more chance with its edges trimmed.
      t=$(printf '%s' "$r" | sed -E 's/^[^[:alnum:]]+//; s/[^[:alnum:]]+$//')
      if [[ ${#t} -ge 5 ]] && grep -qF -- "$t" "$INSTALL_SQ"; then matched+=("$t"); continue; fi
      missing+=("$r")
    done
    if [[ $checked -eq 0 ]]; then
      warn "README shows the transcript line '$short' and every word in it is machine-specific" \
           "nothing in it can be held against install.sh, so it can drift freely"
    elif [[ ${#missing[@]} -gt 0 ]]; then
      fail "README shows a transcript line install.sh never prints: '$q'" \
           "not found in install.sh: $(printf "'%s' " "${missing[@]}")" \
           "a fenced transcript is a promise about what THIS installer prints — a reader compares their run against it"
    else
      # Every run is install.sh's wording; they must also be ONE of its
      # messages. Runs borrowed from three different lines are a sentence the
      # installer cannot produce, however familiar each fragment looks.
      same=1
      if [[ ${#matched[@]} -ge 2 ]]; then
        same=0
        while IFS= read -r line; do
          all=1
          for r in "${matched[@]}"; do [[ $line == *"$r"* ]] || { all=0; break; }; done
          [[ $all -eq 1 ]] && { same=1; break; }
        done < "$INSTALL_SQ"
      fi
      if [[ $same -eq 1 ]]; then
        pass "README transcript '$short' is a line install.sh prints"
      else
        fail "README shows a transcript line spliced from different install.sh messages: '$q'" \
             "each of $(printf "'%s' " "${matched[@]}")is in install.sh, but no single line prints them together" \
             "no run of this installer can produce that line"
      fi
    fi
  fi
done < <( {
    # backtick-quoted spans starting with an installer glyph = TEMPLATES
    grep -oE '`[[:space:]]*(✓|✗|!|·) [^`]*`' "$README" | sed -E 's/^`//; s/`$//; s/^/TPL|/'
    # the same lines inside a fenced code block = one machine's TRANSCRIPT
    awk '/^```/{f=!f; next} f && /^[[:space:]]*(✓|✗|!|·) /{print "SAMPLE|" $0}' "$README"
  } | sort -u )
rm -f "$INSTALL_SQ"
if [[ $n_quoted -eq 0 ]]; then
  warn "the README quotes no installer output at all" \
       "a user has nothing to compare their run against, which is how a no-op passed for a success"
else
  info "$n_quoted quoted installer line(s) checked against install.sh"
fi

# ===========================================================================
section "one canonical copy of every script"
# Two files with the same name and different contents is how a user ends up
# running the older one. verify.sh drifted exactly this way: install.sh's last
# screen said `sudo $HERE/verify.sh` (the root copy) while the README said
# `sudo ./tools/verify.sh`, and the root copy was 37 lines behind -- missing the
# stale-module and psys-reason diagnostics, i.e. unable to detect the failure
# install.sh had warned about eight lines earlier. That shipped because this
# check was a WARN and CI stayed green. It is a FAIL now.
#
# Symlinks are scanned too: one file under two names is the fix, and it only
# works if the link resolves inside the package.
mapfile -t NODES < <(find "$ROOT" -path "$ROOT/.git" -prune -o -name '*.sh' \( -type f -o -type l \) -print | sort)
declare -A SEEN=()
for f in "${NODES[@]}"; do
  b=$(basename "$f"); rf=$(rel "$f")
  if [[ -L $f ]]; then
    tgt=$(readlink -f "$f")
    if [[ -z $tgt || ! -e $tgt ]]; then
      fail "$rf is a DANGLING symlink -> $(readlink "$f")" \
           "anyone following an instruction that names it gets 'No such file or directory'"
      continue
    fi
    case $tgt in
      "$ROOT"/*) ;;
      *) fail "$rf points OUTSIDE the package -> $tgt" \
              "it resolves on the author's machine and nowhere else"; continue ;;
    esac
  fi
  if [[ -n ${SEEN[$b]:-} ]]; then
    o=${SEEN[$b]}
    if [[ $(readlink -f "$f") == "$(readlink -f "$o")" ]]; then
      pass "$b: $(rel "$o") and $rf are the same file — they cannot drift"
    elif cmp -s "$f" "$o"; then
      warn "$b is shipped twice as two separate files: $(rel "$o") and $rf" \
           "byte-identical today, and nothing keeps them that way — make one a symlink to the other"
    else
      fail "$b exists twice with DIFFERENT contents: $(rel "$o") vs $rf" \
           "$(diff "$o" "$f" | grep -c '^[<>]') differing lines — whichever the user was told to run, the other is stale" \
           "keep one file and point every reference at it (a symlink counts)"
    fi
  else
    SEEN[$b]=$f
  fi
done

# ===========================================================================
printf '\n%s──────── selftest summary ────────%s\n' "$C_B" "$C_0"
printf '  %spassed %d%s   %swarnings %d%s   %sfailed %d%s\n' \
  "$C_G" "$n_pass" "$C_0" "$C_Y" "$n_warn" "$C_0" "$C_R" "$n_fail" "$C_0"
if [[ $n_warn -gt 0 ]]; then
  printf '\n  %swarnings%s (not fatal, but a stranger will hit them):\n' "$C_Y" "$C_0"
  for w in "${WARNS[@]}"; do printf '    - %s\n' "$w"; done
fi
if [[ $n_fail -gt 0 ]]; then
  printf '\n  %sfailures%s:\n' "$C_R" "$C_0"
  for f in "${FAILS[@]}"; do printf '    - %s\n' "$f"; done
  printf '\n  %sFAIL%s — as shipped, this package would not install what it claims to.\n' "$C_R" "$C_0"
  exit 1
fi
printf '\n  %sPASS%s — the package is internally consistent.\n' "$C_G" "$C_0"
printf '  This says nothing about whether any camera works: no hardware was\n'
printf '  touched and none can be. It says the installer will find everything\n'
printf '  it is about to install.\n'
exit 0
