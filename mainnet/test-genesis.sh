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
#   BIN           path to the peercash binary (default: /usr/local/bin/peercash,
#                 then ../build/geth-randomx). Legacy: GETH= is still honored.
#   GENESIS       path to the mainnet genesis.json      (default: ./genesis.json next to this script)
#   RUNS          number of deterministic init runs     (default: 5)
#   MINE_TIMEOUT  seconds to wait for block 1            (default: 600)
#   GETH_RANDOMX_THREADS  mining threads (passed through to the binary)
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
ipc="$d/geth.ipc"
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

info "  node started (pid $GETHPID); waiting up to ${MINE_TIMEOUT}s for block 1..."
BN=0
waited=0
while [ "$waited" -lt "$MINE_TIMEOUT" ]; do
  if ! kill -0 "$GETHPID" >/dev/null 2>&1; then
    cat "$WORK/mine.log" >&2; fail "node exited before producing a block"
  fi
  BN="$(run_bin attach "$ipc" --exec 'eth.blockNumber' 2>/dev/null | tr -dc '0-9')"
  BN="${BN:-0}"
  if [ "$BN" -ge 1 ] 2>/dev/null; then break; fi
  sleep 3
  waited=$((waited + 3))
done

[ "$BN" -ge 1 ] 2>/dev/null || { tail -40 "$WORK/mine.log" >&2; fail "no block mined within ${MINE_TIMEOUT}s"; }

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
