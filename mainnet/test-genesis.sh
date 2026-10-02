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
#   ./test-genesis.sh
# Env overrides:
#   GETH          path to the peercash/geth-randomx binary (default: ../build/geth-randomx)
#   GENESIS       path to the mainnet genesis.json      (default: ./genesis.json next to this script)
#   RUNS          number of deterministic init runs     (default: 5)
#   MINE_TIMEOUT  seconds to wait for block 1            (default: 600)
#   GETH_RANDOMX_THREADS  mining threads (passed through to the binary)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GETH="${GETH:-$HERE/../build/geth-randomx}"
GENESIS="${GENESIS:-$HERE/genesis.json}"
RUNS="${RUNS:-5}"
MINE_TIMEOUT="${MINE_TIMEOUT:-600}"
EXPECT_CHAINID=620156

fail() { echo "FAIL: $*" >&2; exit 1; }
info() { echo ">> $*"; }

[ -x "$GETH" ] || fail "geth binary not found/executable at: $GETH (build it first, or set GETH=)"
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
  # Pull the 32-byte genesis hash out of geth init's log output.
  grep -iE 'genesis' "$1" | grep -oiE '0x[0-9a-f]{64}' | head -n1
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
  "$GETH" --datadir "$d" init "$GENESIS" >"$log" 2>&1 \
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
ipc="$d/geth.ipc"
mkdir -p "$d"
"$GETH" --datadir "$d" init "$GENESIS" >"$WORK/mine-init.log" 2>&1 \
  || { cat "$WORK/mine-init.log" >&2; fail "mine-datadir init failed"; }

"$GETH" --datadir "$d" \
  --networkid "$EXPECT_CHAINID" \
  --nodiscover --maxpeers 0 \
  --ipcpath "$ipc" \
  --mine --miner.etherbase 0x0000000000000000000000000000000000000001 \
  --verbosity 3 >"$WORK/mine.log" 2>&1 &
GETHPID=$!

info "  node started (pid $GETHPID); waiting up to ${MINE_TIMEOUT}s for block 1..."
BN=0
waited=0
while [ "$waited" -lt "$MINE_TIMEOUT" ]; do
  if ! kill -0 "$GETHPID" >/dev/null 2>&1; then
    cat "$WORK/mine.log" >&2; fail "node exited before producing a block"
  fi
  BN="$("$GETH" attach "$ipc" --exec 'eth.blockNumber' 2>/dev/null | tr -dc '0-9')"
  BN="${BN:-0}"
  if [ "$BN" -ge 1 ] 2>/dev/null; then break; fi
  sleep 3
  waited=$((waited + 3))
done

[ "$BN" -ge 1 ] 2>/dev/null || { tail -40 "$WORK/mine.log" >&2; fail "no block mined within ${MINE_TIMEOUT}s"; }

B0="$("$GETH" attach "$ipc" --exec 'eth.getBlock(0).hash' 2>/dev/null | tr -d '"'[:space:])"
D1="$("$GETH" attach "$ipc" --exec 'eth.getBlock(1).difficulty' 2>/dev/null | tr -dc '0-9')"
info "  block 0 hash   = $B0"
info "  block 1 number = $BN, difficulty = $D1"

# Block 0 hash from a live node must match the deterministic init hash.
[ "$B0" = "$FIRST_HASH" ] || fail "running node block-0 hash ($B0) != init hash ($FIRST_HASH)"
[ "$D1" = "$GENDIFF_DEC" ] || fail "block 1 difficulty ($D1) != genesis difficulty ($GENDIFF_DEC)"

info "Phase 3 PASS: mined block $BN; block 1 difficulty matches genesis; node healthy"

echo
echo "================ ALL CHECKS PASSED ================"
echo " genesis hash (deterministic): $FIRST_HASH"
echo " chainId:                      $EXPECT_CHAINID"
echo " alloc:                        empty (no premine)"
echo " block 1 difficulty:           $GENDIFF_DEC ($GENDIFF_HEX)"
echo
echo " SHA256 of genesis.json (record this when you freeze it):"
if command -v sha256sum >/dev/null 2>&1; then sha256sum "$GENESIS"; else shasum -a 256 "$GENESIS"; fi
echo "==================================================="
