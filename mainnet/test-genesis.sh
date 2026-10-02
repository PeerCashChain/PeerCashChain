#!/usr/bin/env bash
# PeerCash MAINNET genesis reliability test (RULE 4).
#
# Given mainnet/genesis.json, this script, on clean temp datadirs:
#   1. init N times -> confirms the genesis hash is identical every run
#   2. confirms the alloc is empty (fair launch, no premine)
#   3. starts a node and mines block 1, confirming it mines at the genesis
#      difficulty and the node is healthy
# and reports PASS/FAIL. Run it yourself before treating any genesis as real;
# nothing here freezes the genesis -- freezing (recording the SHA256) is yours.
#
# Usage:
#   ./test-genesis.sh                 # quick test: determinism + alloc + block 1
#   CALIBRATE=1 ./test-genesis.sh     # also mine past the LWMA window and report
#                                     # steady-state block interval + difficulty
#
# The quick test only proves block 1 mines at the GENESIS difficulty. Block 1's
# solve time is NOT steady-state: during the LWMA warmup (blocks 1..window) the
# retarget holds the genesis value, and real timing only settles once LWMA is
# active (block window+1 onward). Use CALIBRATE=1 to tune the genesis difficulty
# against that settled timing instead of the genesis value.
#
# Env overrides:
#   BIN           path to the peercash binary (default: /usr/local/bin/peercash,
#                 then ../build/geth-randomx). Legacy: GETH= is still honored.
#   GENESIS       path to the mainnet genesis.json      (default: ./genesis.json next to this script)
#   RUNS          number of deterministic init runs     (default: 5)
#   MINE_TIMEOUT  seconds to wait for block 1            (default: 600)
#   GETH_RANDOMX_THREADS  mining threads (passed through to the binary)
#   Calibration mode (only when CALIBRATE is set to a non-empty/1/true value):
#   CALIBRATE_BLOCKS   target height to mine to          (default: 75)
#   CALIBRATE_TIMEOUT  seconds to wait for that height   (default: 1800)
#   LWMA_WINDOW        LWMA warmup window in blocks       (default: 60; interval
#                      is averaged over blocks LWMA_WINDOW+1 .. target)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Binary path. Honor BIN=, then legacy GETH=, else prefer an installed peercash,
# then a local build. GETH is consumed as a SHELL variable only; run_bin strips
# it from the binary's environment so it is never seen as a config env var (the
# node warns "Unknown config environment variable envvar=GETH" otherwise).
BIN="${BIN:-${GETH:-}}"
if [ -z "$BIN" ]; then
  if [ -x /usr/local/bin/peercash ]; then
    BIN=/usr/local/bin/peercash
  else
    BIN="$HERE/../build/geth-randomx"
  fi
fi
GENESIS="${GENESIS:-$HERE/genesis.json}"
RUNS="${RUNS:-5}"
MINE_TIMEOUT="${MINE_TIMEOUT:-600}"
EXPECT_CHAINID=620156

# Calibration mode (opt-in). When enabled, Phase 3 mines to CALIBRATE_BLOCKS
# instead of stopping at block 1, then reports steady-state timing/difficulty.
CALIBRATE="${CALIBRATE:-}"
case "$CALIBRATE" in 1|true|TRUE|yes|YES|on|ON) CALIBRATE=1 ;; *) CALIBRATE="" ;; esac
CALIBRATE_BLOCKS="${CALIBRATE_BLOCKS:-75}"
CALIBRATE_TIMEOUT="${CALIBRATE_TIMEOUT:-1800}"
LWMA_WINDOW="${LWMA_WINDOW:-60}"

# How high to mine and how long to wait depend on the mode.
if [ -n "$CALIBRATE" ]; then
  TARGET_BLOCK="$CALIBRATE_BLOCKS"
  WAIT_TIMEOUT="$CALIBRATE_TIMEOUT"
  if [ "$TARGET_BLOCK" -le "$LWMA_WINDOW" ] 2>/dev/null; then
    fail "CALIBRATE_BLOCKS ($TARGET_BLOCK) must exceed LWMA_WINDOW ($LWMA_WINDOW) to measure steady state"
  fi
else
  TARGET_BLOCK=1
  WAIT_TIMEOUT="$MINE_TIMEOUT"
fi

# Run the node binary with GETH stripped from its environment (shell-only var).
run_bin() { env -u GETH "$BIN" "$@"; }

fail() { echo "FAIL: $*" >&2; exit 1; }
info() { echo ">> $*"; }

[ -x "$BIN" ] || fail "peercash binary not found/executable at: $BIN (build it first, or set BIN=)"
[ -f "$GENESIS" ] || fail "genesis not found at: $GENESIS"

# Sanity: the genesis must be our mainnet chainId, never a testnet id.
grep -q '"chainId"[[:space:]]*:[[:space:]]*'"$EXPECT_CHAINID" "$GENESIS" \
  || fail "genesis chainId is not $EXPECT_CHAINID -- refusing to test the wrong network"
for bad in 563321 61102 271017 563320; do
  if grep -q "$bad" "$GENESIS"; then fail "genesis contains forbidden id $bad (testnet/devnet/stale leak)"; fi
done

WORK="$(mktemp -d)"
GETHPID=""
cleanup() {
  [ -n "$GETHPID" ] && kill "$GETHPID" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

extract_hash() {
  # Pull the genesis hash out of the node's init output. This binary logs to
  # STDERR (captured via 2>&1 at the call site) on the line:
  #   Successfully wrote genesis state  database=chaindata hash=671661..2a6a26
  # The hash is ABBREVIATED by common.Hash.TerminalString(): first 3 bytes, "..",
  # then last 3 bytes (6 hex + ".." + 6 hex) -- NOT a full 0x64-hex string.
  # Accept either the abbreviated form or a full 0x hash (whichever the build
  # emits), keyed off the hash= field, and return it verbatim. For the
  # determinism check this string is stable: identical genesis -> identical
  # abbreviation every run. The "wrote genesis state" line is matched first.
  { grep -iE 'wrote genesis state' "$1"; grep -iE 'genesis' "$1"; } \
    | grep -oiE 'hash=(0x[0-9a-f]{64}|[0-9a-f]{6}\.\.[0-9a-f]{6})' \
    | head -n1 | sed 's/^[Hh]ash=//'
}

############################################
# Phase 1: deterministic genesis hash
############################################
info "Phase 1: init $RUNS times on clean datadirs, compare genesis hash"
FIRST_HASH=""
for i in $(seq 1 "$RUNS"); do
  d="$WORK/init-$i"
  log="$WORK/init-$i.log"
  mkdir -p "$d"
  run_bin --datadir "$d" init "$GENESIS" >"$log" 2>&1 \
    || { cat "$log" >&2; fail "init run $i failed"; }
  h="$(extract_hash "$log")"
  [ -n "$h" ] || { cat "$log" >&2; fail "could not parse genesis hash from init run $i"; }
  info "  run $i: $h"
  if [ -z "$FIRST_HASH" ]; then
    FIRST_HASH="$h"
  elif [ "$h" != "$FIRST_HASH" ]; then
    fail "genesis hash MISMATCH on run $i: $h != $FIRST_HASH (non-deterministic genesis)"
  fi
done
info "Phase 1 PASS: deterministic genesis hash = $FIRST_HASH"

############################################
# Phase 2: empty alloc (no premine)
############################################
info "Phase 2: verify empty alloc (fair launch, no premine)"
# Collapse whitespace and check "alloc": {} exactly. If jq is present, prefer it.
if command -v jq >/dev/null 2>&1; then
  n="$(jq '.alloc | length' "$GENESIS")"
  [ "$n" = "0" ] || fail "alloc is non-empty ($n account(s)) -- premine present"
else
  compact="$(tr -d ' \t\r\n' < "$GENESIS")"
  echo "$compact" | grep -q '"alloc":{}' \
    || fail 'alloc is not exactly {} -- inspect genesis for a premine'
fi
info "Phase 2 PASS: alloc is empty"

############################################
# Phase 3: mine block 1 at the genesis difficulty
############################################
info "Phase 3: start node, mine block 1, verify difficulty + health"
# Genesis difficulty (hex) -> decimal. Blocks 1..60 hold the genesis difficulty
# (LWMA warmup), so block 1 must mine at exactly this value.
GENDIFF_HEX="$(tr -d ' \t\r\n' < "$GENESIS" | grep -oiE '"difficulty":"0x[0-9a-f]+"' | grep -oiE '0x[0-9a-f]+' | head -n1)"
[ -n "$GENDIFF_HEX" ] || fail "could not read difficulty from genesis"
GENDIFF_DEC=$(( GENDIFF_HEX ))
info "  genesis difficulty = $GENDIFF_HEX ($GENDIFF_DEC)"

d="$WORK/mine"
ipc="$d/peercash.ipc"
mkdir -p "$d"
run_bin --datadir "$d" init "$GENESIS" >"$WORK/mine-init.log" 2>&1 \
  || { cat "$WORK/mine-init.log" >&2; fail "mine-datadir init failed"; }

# Create a REAL throwaway miner account and mine to it. The sealer only produces
# blocks for an etherbase that exists in this datadir's keystore; mining to a
# placeholder address (e.g. 0x...001) silently never seals -- which previously
# looked like a difficulty problem but was this bug. The key is disposable: it
# lives only in the temp datadir, which cleanup() removes on exit.
PWFILE="$d/miner-pass.txt"
echo "peercash-genesis-test" > "$PWFILE"
ETHERBASE="$(run_bin --datadir "$d" account new --password "$PWFILE" 2>&1 \
  | grep -oiE '0x[0-9a-f]{40}' | head -n1)"
[ -n "$ETHERBASE" ] || fail "could not create/parse throwaway miner account"
info "  mining to throwaway account $ETHERBASE"

run_bin --datadir "$d" \
  --networkid "$EXPECT_CHAINID" \
  --nodiscover --maxpeers 0 \
  --ipcpath "$ipc" \
  --mine --miner.etherbase "$ETHERBASE" \
  --verbosity 3 >"$WORK/mine.log" 2>&1 &
GETHPID=$!

info "  node started (pid $GETHPID); waiting up to ${WAIT_TIMEOUT}s for block ${TARGET_BLOCK}..."
BN=0
waited=0
while [ "$waited" -lt "$WAIT_TIMEOUT" ]; do
  if ! kill -0 "$GETHPID" >/dev/null 2>&1; then
    cat "$WORK/mine.log" >&2; fail "node exited before producing a block"
  fi
  BN="$(run_bin attach "$ipc" --exec 'eth.blockNumber' 2>/dev/null | tr -dc '0-9')"
  BN="${BN:-0}"
  if [ "$BN" -ge "$TARGET_BLOCK" ] 2>/dev/null; then break; fi
  sleep 3
  waited=$((waited + 3))
done

[ "$BN" -ge "$TARGET_BLOCK" ] 2>/dev/null || { tail -40 "$WORK/mine.log" >&2; fail "only reached block $BN (target $TARGET_BLOCK) within ${WAIT_TIMEOUT}s"; }

B0="$(run_bin attach "$ipc" --exec 'eth.getBlock(0).hash' 2>/dev/null | tr -d '"' | tr -d '[:space:]')"
D1="$(run_bin attach "$ipc" --exec 'eth.getBlock(1).difficulty' 2>/dev/null | tr -dc '0-9')"

# FIRST_HASH is the ABBREVIATED hash from init logs (6hex..6hex); B0 is the FULL
# 0x hash from the live node. Reduce B0 to the same abbreviation (first 3 + last
# 3 bytes) before comparing, rather than requiring raw string equality.
b0_nox="$(printf '%s' "$B0" | tr 'A-F' 'a-f')"; b0_nox="${b0_nox#0x}"
if printf '%s' "$FIRST_HASH" | grep -qiE '^0x[0-9a-f]{64}$'; then
  b0_cmp="0x$b0_nox"                    # init emitted a full hash too
else
  b0_cmp="${b0_nox:0:6}..${b0_nox: -6}" # init emitted the abbreviated form
fi
info "  block 0 hash   = $B0 (compare: $b0_cmp)"
info "  block 1 number = $BN, difficulty = $D1"

# Block 0 hash from the live node must match the deterministic init hash.
[ "$b0_cmp" = "$FIRST_HASH" ] || fail "running node block-0 hash ($B0 -> $b0_cmp) != init hash ($FIRST_HASH)"
[ "$D1" = "$GENDIFF_DEC" ] || fail "block 1 difficulty ($D1) != genesis difficulty ($GENDIFF_DEC)"

info "Phase 3 PASS: mined block $BN; block 1 difficulty matches genesis; node healthy"

############################################
# Phase 4 (optional): steady-state calibration
############################################
# Only runs under CALIBRATE=1. Blocks 1..LWMA_WINDOW hold the genesis difficulty
# (warmup); real timing settles once LWMA is active, so we measure the average
# block interval and the retargeted difficulty over blocks LWMA_WINDOW+1..tip.
CAL_AVG=""; CAL_DTIP=""; CAL_DTIP_HEX=""; CAL_DAVG=""; CAL_DMIN=""; CAL_DMAX=""; CAL_WS=""; CAL_MAX=""
if [ -n "$CALIBRATE" ]; then
  info "Phase 4: calibrate steady-state over blocks $((LWMA_WINDOW + 1))..$BN"
  # One attach call dumps "number timestamp difficulty" for every block.
  STATS_JS="var o=[];for(var i=0;i<=$BN;i++){var b=eth.getBlock(i);if(b==null){continue;}o.push(b.number+' '+b.timestamp+' '+(''+b.difficulty));}console.log(o.join('\n'));"
  run_bin attach "$ipc" --exec "$STATS_JS" 2>/dev/null \
    | tr -d '\r' | grep -E '^[0-9]+ [0-9]+ [0-9]+$' > "$WORK/blocks.txt"
  [ -s "$WORK/blocks.txt" ] || fail "calibration: could not collect per-block data"

  CAL_OUT="$(awk -v ws="$((LWMA_WINDOW + 1))" '
    { n=$1; ts[n]=$2; df[n]=$3; if (n>max) max=n }
    END {
      if (max < ws) { print "ERR"; exit 0 }
      span = ts[max] - ts[ws-1];     # seconds spanned by the LWMA-active range
      nint = max - (ws-1);           # intervals in that range
      avg  = (nint>0) ? span/nint : 0;
      sum=0; cnt=0; dmin=df[ws]; dmax=df[ws];
      for (i=ws; i<=max; i++) {
        sum += df[i]; cnt++;
        if (df[i] < dmin) dmin = df[i];
        if (df[i] > dmax) dmax = df[i];
      }
      davg = (cnt>0) ? sum/cnt : 0;
      printf "%d %d %.2f %s %.0f %.0f %.0f\n", ws, max, avg, df[max], davg, dmin, dmax;
    }' "$WORK/blocks.txt")"

  [ "$CAL_OUT" = "ERR" ] && fail "calibration: not enough blocks past the LWMA window (have $BN, need > $LWMA_WINDOW)"
  read -r CAL_WS CAL_MAX CAL_AVG CAL_DTIP CAL_DAVG CAL_DMIN CAL_DMAX <<EOF
$CAL_OUT
EOF
  CAL_DTIP_HEX="$(printf '0x%x' "$CAL_DTIP" 2>/dev/null || echo 'n/a')"

  info "Phase 4 results (steady-state, blocks ${CAL_WS}..${CAL_MAX}):"
  info "  avg block interval = ${CAL_AVG}s  (LWMA target is 12s)"
  info "  retargeted difficulty = ${CAL_DTIP} (${CAL_DTIP_HEX}) at tip; avg ${CAL_DAVG}, min ${CAL_DMIN}, max ${CAL_DMAX}"
fi

echo
echo "================ ALL CHECKS PASSED ================"
echo " genesis hash (deterministic): $FIRST_HASH"
echo " chainId:                      $EXPECT_CHAINID"
echo " alloc:                        empty (no premine)"
echo " block 1 difficulty:           $GENDIFF_DEC ($GENDIFF_HEX)"
if [ -n "$CALIBRATE" ]; then
echo
echo " -- calibration (steady-state, blocks ${CAL_WS}..${CAL_MAX}) --"
echo " avg block interval:           ${CAL_AVG}s (LWMA target 12s)"
echo " retargeted difficulty (tip):  ${CAL_DTIP} (${CAL_DTIP_HEX})"
echo " retargeted difficulty range:  min ${CAL_DMIN}, avg ${CAL_DAVG}, max ${CAL_DMAX}"
echo " NOTE: tune GENESIS difficulty toward the retargeted value above, not the"
echo "       genesis value -- genesis difficulty only sets the warmup solve time."
fi
echo
echo " SHA256 of genesis.json (record this when you freeze it):"
if command -v sha256sum >/dev/null 2>&1; then sha256sum "$GENESIS"; else shasum -a 256 "$GENESIS"; fi
echo "==================================================="
