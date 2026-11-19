#!/usr/bin/env bash
#
# mayhem/test.sh — RUN aide's functional oracle (built by mayhem/build.sh with normal flags):
#   * upstream's libcheck unit suite (check_aide), counted from its `N%: Checks: C, Failures: F, Errors: E` line
#   * known-answer probes on the aide CLI over committed fixtures in mayhem/test/: --list (+--limit),
#     --compare (json + plain report values), --path-check rule matching, and a config error message.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}


OUT="$SRC/mayhem/out"
FIX="$SRC/mayhem/test"
AIDE="$OUT/aide"
for f in "$AIDE" "$OUT/check_aide"; do
  [ -x "$f" ] || { echo "missing $f — run mayhem/build.sh first" >&2; emit_ctrf aide-check 0 1; exit 1; }
done
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aide-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

passed=0; failed=0
ok()   { echo "PASS: $1"; passed=$((passed+1)); }
bad()  { echo "FAIL: $1"; failed=$((failed+1)); }

# 1) upstream unit suite
log="$WORK/check.log"
(cd "$WORK" && "$OUT/check_aide") >"$log" 2>&1
line="$(grep -E '^[0-9]+%: Checks: [0-9]+, Failures: [0-9]+, Errors: [0-9]+' "$log" | tail -1)"
if [ -n "$line" ]; then
  c="$(sed -E 's/.*Checks: ([0-9]+).*/\1/' <<<"$line")"
  f="$(sed -E 's/.*Failures: ([0-9]+).*/\1/' <<<"$line")"
  e="$(sed -E 's/.*Errors: ([0-9]+).*/\1/' <<<"$line")"
  echo "check_aide: $line"
  passed=$((passed + c - f - e)); failed=$((failed + f + e))
  [ "$c" -ge 100 ] || bad "check_aide ran only $c checks"
else
  tail -20 "$log"; bad "check_aide produced no summary line"
fi

# expect <name> <file> <fixed string>...: every string must appear in the file
expect() {
  local name="$1" file="$2"; shift 2
  local s
  for s in "$@"; do
    grep -qF -- "$s" "$file" || { echo "  missing: $s"; bad "$name"; return; }
  done
  ok "$name"
}

# 2) --list with --limit over the fixture database (percent-decoding, hashes in base16, ACLs)
printf 'database_in=file:%s/list.db\n' "$FIX" > "$WORK/list.conf"
(cd "$WORK" && "$AIDE" -c list.conf --list --limit /etc/d/s) > "$WORK/list.out" 2>&1
expect "list: limited entries" "$WORK/list.out" \
  "/etc/d/sub/b" \
  "SHA256    : 73cb3858a687a8494ca3323053016282f3dad39d42cf62ca4e79dda2aac7d9ac" \
  "RMD160    : 6202a78e3f1ccde4446e8a75203107add8f5fdc8" \
  "A: user::rw-"
if grep -qF "/etc/d/a file" "$WORK/list.out"; then bad "list: limit excludes /etc/d/a file"; else ok "list: limit excludes /etc/d/a file"; fi
(cd "$WORK" && "$AIDE" -c list.conf --list) > "$WORK/listall.out" 2>&1
expect "list: decoded file names" "$WORK/listall.out" "/etc/d/a file" "Lname     : a file" "/etc/d/äx"

# 3) --compare, json report
printf 'database_in=file:%s/old.db\ndatabase_new=file:%s/new.db\nreport_format=json\n' "$FIX" "$FIX" > "$WORK/cmp.conf"
(cd "$WORK" && "$AIDE" -c cmp.conf --compare --no-progress) > "$WORK/cmp.json" 2>&1; rc=$?
[ "$rc" -eq 7 ] && ok "compare: exit code 7 (added+removed+changed)" || bad "compare: exit code $rc (want 7)"
expect "compare: json counts" "$WORK/cmp.json" \
  '"total": 7,' '"added": 1,' '"removed": 1,' '"changed": 1' \
  '"/etc/d/lnk": "l+++++++++++++++"' '"/etc/d/sub/b": "f < p.. ....... "' \
  '"sha256": "0vTEZrRUvn9UCubnQ9yg1zMPrRJLRFUBzG4Wr9GO97s="'
# 4) --compare, plain report details
printf 'database_in=file:%s/old.db\ndatabase_new=file:%s/new.db\n' "$FIX" "$FIX" > "$WORK/cmp2.conf"
(cd "$WORK" && "$AIDE" -c cmp2.conf --compare --no-progress) > "$WORK/cmp.txt" 2>&1
expect "compare: plain details" "$WORK/cmp.txt" \
  "d---------------: /etc/extra\\011tab" \
  " Size      : 3                                | 2" \
  " Perm      : -rw-------                       | -rw-r--r--"

# 5) config: rule matching via --path-check, and a config error
pc() { (cd "$WORK" && "$AIDE" -c "$FIX/rules.conf" --path-check "$1") 2>/dev/null; }
pc f:/etc/hosts > "$WORK/pc1"; pc f:/etc/mtab > "$WORK/pc2"; pc d:/var/log > "$WORK/pc3"; pc f:/boot/x > "$WORK/pc4"
expect "path-check: selective rule" "$WORK/pc1" "[x] f:/etc/hosts: selective rule: '/etc/hosts f p+u+g+n+acl+sha256+xattrs+ftype'"
expect "path-check: negative rule" "$WORK/pc2" "[ ] f:/etc/mtab: recursive negative rule: '!/etc/mtab\$ (none)'"
expect "path-check: equal rule" "$WORK/pc3" "[x] d:/var/log: equal rule: '=/var/log\$ (none) p+u+g+i+n+acl+xattrs'"
expect "path-check: macro-expanded group" "$WORK/pc4" "[x] f:/boot/x: selective rule: '/boot/ (none) l+p+u+g+s+c+m+i+n+acl+xattrs+ftype+sha3_256'"
printf 'Foo = p+u\n/etc Bar\n' > "$WORK/bad.conf"
(cd "$WORK" && "$AIDE" -c bad.conf --config-check) > "$WORK/bad.out" 2>&1; rc=$?
[ "$rc" -eq 17 ] && ok "config-check: exit 17 on bad config" || bad "config-check: exit $rc (want 17)"
expect "config-check: error message" "$WORK/bad.out" "bad.conf:2: group 'Bar' is not defined"

emit_ctrf aide-check "$passed" "$failed" 0
