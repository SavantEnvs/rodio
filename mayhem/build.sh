#!/usr/bin/env bash
#
# mayhem/build.sh — build rodio's additive mayhem/fuzz/ cargo-fuzz crate (target: `decode`,
# rodio::Decoder::new over arbitrary bytes — see mayhem/fuzz/fuzz_targets/decode.rs), the
# additive mayhem/kat/ known-answer-test probe, and precompile rodio's own test suite.
#
# rodio ships NO fuzz/ dir upstream (net-new port; not an OSS-Fuzz project either) — everything
# under mayhem/ here is additive, upstream files are untouched.
#
# cargo-fuzz drives the fuzz build:
#   - it provides its own libFuzzer runtime (the produced binary IS a libFuzzer target — Mayhem
#     runs it directly via `libfuzzer: true`);
#   - ASan is enabled the Rust way, through RUSTFLAGS `-Zsanitizer=address` (NOT clang's
#     $SANITIZER_FLAGS/$CFLAGS — those don't apply to rustc). nightly is required for
#     `-Zsanitizer`.
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE. This first
# (online) build populates the cargo registry under $CARGO_HOME (pinned, $HOME-independent — see
# the Dockerfile). Do NOT pass --offline here; the rlenv runtime exports CARGO_NET_OFFLINE=true
# for the re-run.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SRC:=/mayhem}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C llvm-args=--dwarf-version=3}"
export MAYHEM_JOBS
export RUST_DEBUG_FLAGS
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# DWARF anchor: rustc's ASan codegen (-Zsanitizer=address) unconditionally emits DWARF5 for
# EVERY compilation unit — a known, fleet-wide rustc/LLVM limitation, not fixable by rustc flags
# alone (see docs/netnew-worker-prompt.md §6 "Rust — the DWARF3 anchor must be PREPENDED", and
# this fleet's regex/bumpalo ports). verify-repo.sh's DWARF gate reads only the FIRST
# compilation unit's version, so prepend a tiny hand-built DWARF3 object as the FIRST linker
# input via a custom `-C linker=` wrapper — it carries no runtime code, only a debug-info CU.
# Must be PREPENDED ("$ANCHOR_O" before "$@"), never appended, or its CU doesn't land at
# .debug_info offset 0 and the gate still fails.
ANCHOR_C=/tmp/mayhem-dwarf-anchor.c
ANCHOR_O=/tmp/mayhem-dwarf-anchor.o
LINKER_WRAP=/tmp/mayhem-dwarf-linker.sh
cat > "$ANCHOR_C" <<'EOF'
int __mayhem_dwarf3_anchor;
EOF
clang -O0 -gdwarf-3 -c "$ANCHOR_C" -o "$ANCHOR_O"
cat > "$LINKER_WRAP" <<EOF
#!/bin/sh
exec clang "$ANCHOR_O" "\$@"
EOF
chmod +x "$LINKER_WRAP"

FUZZ_DIR="mayhem/fuzz"
FUZZ_TARGETS=()
for f in "$FUZZ_DIR"/fuzz_targets/*.rs; do
  FUZZ_TARGETS+=("$(basename "${f%.*}")")
done
[ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $FUZZ_DIR/fuzz_targets/" >&2; exit 1; }
TRIPLE="x86_64-unknown-linux-gnu"

# Replicate OSS-Fuzz `compile` RUSTFLAGS for a libFuzzer+ASan Rust build. `--cfg fuzzing`
# matches what libfuzzer-sys expects; force-frame-pointers aids ASan stack traces.
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing -Zsanitizer=address -Cdebuginfo=2 -Cdwarf-version=3 -Cforce-frame-pointers -Csplit-debuginfo=off -Clinker=$LINKER_WRAP $RUST_DEBUG_FLAGS"

echo "=== cargo fuzz build (image-default nightly toolchain, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$t"
  bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t"
  if [ ! -x "$bin" ]; then
    echo "ERROR: expected fuzz binary not found at $bin" >&2
    exit 1
  fi
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

echo "=== build the KAT (known-answer-test) probe — clean, non-sanitized, normal flags ==="
# Separate build from the sanitized fuzz build above: unset RUSTFLAGS/linker wrapper so this
# ordinary binary doesn't inherit -Zsanitizer=address or the DWARF3 linker wrapper. It must stay
# a normal dynamically-linked Rust binary — that's what makes it affected by the sabotage shim's
# LD_PRELOAD constructor (see mayhem/kat/Cargo.toml + mayhem/test.sh for why this exists).
KAT_DIR="mayhem/kat"
(
  cd "$KAT_DIR"
  RUSTFLAGS="" cargo build --release --jobs "$MAYHEM_JOBS"
)
KAT_BIN="$SRC/$KAT_DIR/target/release/rodio-kat"
[ -x "$KAT_BIN" ] || { echo "ERROR: KAT probe not built at $KAT_BIN" >&2; exit 1; }
cp "$KAT_BIN" /mayhem/rodio-kat
# Regression guard (net-new brief §6, "Rust binaries are dynamically linked by default"): assert
# it stayed dynamically linked, since a statically-linked probe would be immune to the sabotage
# shim's LD_PRELOAD and silently weaken the oracle.
if ! file /mayhem/rodio-kat | grep -q 'dynamically linked'; then
  echo "ERROR: /mayhem/rodio-kat is not dynamically linked — the KAT oracle would be" \
       "immune to LD_PRELOAD sabotage. file output:" >&2
  file /mayhem/rodio-kat >&2
  exit 1
fi
echo "built /mayhem/rodio-kat (dynamically linked, confirmed)"

echo "=== precompile rodio's own test suite (hermetic, normal non-sanitized flags) ==="
# mayhem/test.sh only RUNS this, never compiles. RUSTFLAGS cleared so it inherits nothing from
# the ASan build's -Zsanitizer/linker wrapper. Same feature set as the fuzz crate (the
# symphonia-backed default codecs), WITHOUT playback/recording/pulseaudio — those pull in cpal,
# which needs a real audio device and isn't available (or needed) in this build/test image.
# mayhem/fuzz and mayhem/kat each declare their own `[workspace]`, so this (root, implicit
# single-crate) `cargo test` invocation never touches them.
RUSTFLAGS="" cargo test --no-default-features --features wav,flac,mp3,mp4,vorbis \
  --no-run --no-fail-fast --jobs "$MAYHEM_JOBS"

echo "build.sh complete:"
ls -la "/mayhem/${FUZZ_TARGETS[@]}" /mayhem/rodio-kat 2>&1 || true
