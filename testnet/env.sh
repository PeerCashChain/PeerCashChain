#!/usr/bin/env bash
# Shared configuration for the duchain RandomX public testnet.
# Source this from the other scripts: `source env.sh`.

set -euo pipefail

# Absolute path to the geth binary built with `-tags randomx` (see build.sh).
GETH="${GETH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/build/geth-randomx}"

# Network identity. The network id MUST match the genesis chainId.
NETWORK_ID="${NETWORK_ID:-61102}"
GENESIS="${GENESIS:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/genesis.json}"

# Comma-separated bootnode enodes that new nodes dial to discover the network.
# Fill this in with your bootnode's enode (printed by bootnode.sh), including the
# public IP, e.g.:
#   BOOTNODES="enode://<pubkey>@203.0.113.10:30303"
BOOTNODES="${BOOTNODES:-}"

# P2P port and data directory (override per-host / per-role as needed).
PORT="${PORT:-30303}"
DATADIR="${DATADIR:-$HOME/.duchain-testnet}"

# Public IP for this host so peers can reach us. Leave empty on a LAN/dev box.
EXTIP="${EXTIP:-}"

init_if_needed() {
  if [ ! -d "$DATADIR/peercash/chaindata" ]; then
    echo ">> Initialising genesis in $DATADIR"
    "$GETH" --datadir "$DATADIR" init "$GENESIS"
  fi
}

nat_flag() {
  if [ -n "$EXTIP" ]; then echo "--nat extip:$EXTIP"; fi
}

bootnodes_flag() {
  if [ -n "$BOOTNODES" ]; then echo "--bootnodes $BOOTNODES"; fi
}
