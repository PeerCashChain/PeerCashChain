#!/usr/bin/env bash
# Run the testnet BOOTNODE: a stable-identity discovery anchor that other nodes
# dial. It keeps a fixed node key so its enode never changes across restarts.
# Run this first, copy the printed enode into env.sh BOOTNODES on every other host.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

DATADIR="${DATADIR:-$HOME/.duchain-testnet-boot}"
NODEKEY="$DATADIR/nodekey"

mkdir -p "$DATADIR/geth"
init_if_needed

# Generate a persistent node key on first run so the enode is stable.
if [ ! -f "$NODEKEY" ]; then
  echo ">> Generating persistent bootnode key"
  "$GETH" --datadir "$DATADIR" account new --password <(echo "") >/dev/null 2>&1 || true
fi

echo ">> Starting bootnode on port $PORT (datadir $DATADIR)"
echo ">> Once up, run:  peercash attach $DATADIR/peercash.ipc --exec admin.nodeInfo.enode"
echo ">> and put that enode (with public IP) into env.sh BOOTNODES."

exec "$GETH" --datadir "$DATADIR" \
  --networkid "$NETWORK_ID" \
  --port "$PORT" \
  $(nat_flag) \
  --verbosity 3
