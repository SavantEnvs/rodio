#!/usr/bin/env bash
#
# mayhem/test.sh — RUN (never build) what mayhem/build.sh already compiled:
#   1. rodio's own `cargo test` suite (decoder behavior across wav/flac/mp3/mp4/vorbis, seeking,
#      total_duration, limiter, channel volume, ...) — broad coverage, contributes counts.
#   2. the additive KAT (known-answer-test) probe `/mayhem/rodio-kat` — a fixed WAV fixture
#      decoded, asserted against exact values computed INDEPENDENTLY of rodio (see
#      mayhem/kat/src/main.rs). This is the REQUIRED behavioral oracle (net-new brief §4):
#      `cargo test` alone is a FORBIDDEN sole oracle here — it has been observed to keep
#      reporting green under the sabotage shim's LD_PRELOAD _exit(0) constructor. The KAT probe
#      is an ordinary dynamically-linked Rust binary (build.sh asserts this with `file`), so the
#      shim's constructor genuinely fires and the probe never gets to print its PASS/KAT lines —
#      a neutered program FAILS this script.
#
# REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary: a JSON report + a one-line `CTRF {...}`
# stdout marker. Uses the fleet-standard emit_ctrf helper; exit code is 0 iff failed==0.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0

echo "=== 1/2: rodio's own cargo test suite (already built by build.sh) ==="
unset RUSTFLAGS
LOG="$(mktemp)"
cargo test --no-default-features --features wav,flac,mp3,mp4,vorbis --no-fail-fast --jobs "$MAYHEM_JOBS" 2>&1 | tee "$LOG"

# Sum every per-suite "test result: ok. X passed; Y failed; Z ignored ..." line across the whole
# `cargo test` invocation (unit tests in src/, each file under tests/, doc-tests).
read -r P F S <<<"$(awk '/^test result:/ {
  for (i=1;i<=NF;i++) {
    if ($(i+1) ~ /^passed/)  p += $i;
    if ($(i+1) ~ /^failed/)  f += $i;
    if ($(i+1) ~ /^ignored/) s += $i;
  }
} END { printf "%d %d %d", p+0, f+0, s+0 }' "$LOG")"

if [ "$((P + F))" -eq 0 ]; then
  echo "ERROR: no cargo-test results parsed — suite did not run" >&2
  TOTAL_FAIL=$((TOTAL_FAIL + 1))
else
  TOTAL_PASS=$((TOTAL_PASS + P))
  TOTAL_FAIL=$((TOTAL_FAIL + F))
  TOTAL_SKIP=$((TOTAL_SKIP + S))
fi

echo
echo "=== 2/2: KAT probe (behavioral oracle — required, unconditional) ==="
KAT_BIN="$SRC/rodio-kat"
if [ ! -x "$KAT_BIN" ]; then
  echo "ERROR: $KAT_BIN missing — build.sh should have produced it" >&2
  TOTAL_FAIL=$((TOTAL_FAIL + 1))
else
  KAT_LOG="$(mktemp)"
  "$KAT_BIN" >"$KAT_LOG" 2>&1
  kat_rc=$?
  cat "$KAT_LOG"
  # Each `PASS <name>` / `FAIL <name>` line is one assertion; count them directly instead of
  # trusting the exit code alone. This is the load-bearing check: a sabotaged/neutered process
  # (the shim's LD_PRELOAD constructor calling _exit(0) before main() ever runs) exits 0 with
  # ZERO output — trusting `kat_rc == 0` alone would silently pass a neutered run. Requiring at
  # least one parsed PASS/FAIL line is what makes this an oracle a neuter cannot survive.
  kp=$(grep -c '^PASS ' "$KAT_LOG" || true)
  kf=$(grep -c '^FAIL ' "$KAT_LOG" || true)
  if [ "$((kp + kf))" -eq 0 ]; then
    echo "ERROR: rodio-kat produced NO PASS/FAIL assertion lines (rc=$kat_rc) — probe was" \
         "neutered or did not run to completion" >&2
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
  else
    TOTAL_PASS=$((TOTAL_PASS + kp))
    TOTAL_FAIL=$((TOTAL_FAIL + kf))
  fi
fi

echo
echo "=== summary: passed=$TOTAL_PASS failed=$TOTAL_FAIL skipped=$TOTAL_SKIP ==="
emit_ctrf "cargo-test+rodio-kat" "$TOTAL_PASS" "$TOTAL_FAIL" "$TOTAL_SKIP"
