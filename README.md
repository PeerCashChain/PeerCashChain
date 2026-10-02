# PeerCash

**PeerCash** is a sovereign, CPU-mineable, EVM-compatible Layer 1: a fork of
[go-ethereum](https://github.com/ethereum/go-ethereum) (currently rebased on
**v1.17.4**) that replaces post-merge Proof-of-Stake with a standalone
**RandomX Proof-of-Work** engine. It keeps the standard Ethereum EVM, state
machine, and JSON-RPC, so MetaMask, ethers.js, Foundry, Blockscout, and every
standard EVM tool work out of the box — while running as an independent,
PoW-secured chain with no beacon chain, no consensus client, and no staking.

The thesis: **sound money you mine yourself on a normal computer.** Fair launch,
no premine, no VC allocation, **21,000,000 PEER** hard cap.

- **Native currency:** PEER (18 decimals)
- **Consensus:** RandomX PoW, LWMA retarget (~12s target block time, 60-block window)
- **Block reward:** 1 PEER initial, halving every 10,500,000 blocks, converging to a 21,000,000 PEER hard cap
- **Mainnet chainId:** 620156
- **Testnet chainId:** 563321
- **Supply:** no premine — genesis alloc is empty; all supply comes from mining

The mainnet genesis is baked directly into the binary
(`params.MainnetChainConfig`), the same way upstream go-ethereum embeds real
Ethereum mainnet, and a matching [`mainnet/genesis.json`](mainnet/genesis.json)
is published so anyone can verify the embedded parameters and the genesis hash.

> ⚠️ **Status: pre-mainnet, unaudited.** Do not attach real economic value yet.
> See [`SECURITY_REVIEW.md`](SECURITY_REVIEW.md) for the current security posture.

## What's different from upstream go-ethereum

- **RandomX consensus engine** (`consensus/randomx/`) — the CPU-friendly,
  ASIC-resistant PoW used by Monero, swapped in for Ethash/PoS. See
  [`consensus/randomx/README.md`](consensus/randomx/README.md) for how it
  implements `consensus.Engine` and how to build against real `librandomx`.
- **LWMA difficulty retarget** — no difficulty bomb, ~12s target block time,
  60-block averaging window.
- **Total-difficulty fork-choice** — reorgs happen on heaviest-chain (summed
  PoW), like pre-merge Ethereum, instead of LMD-GHOST/finality.
- **Capped, halving block reward** — 1 PEER per block initially, halving every
  10,500,000 blocks, converging to a fixed 21,000,000 PEER supply cap.
- **Fair-launch fee policy** — mainnet runs full EIP-1559 base-fee burn with
  **no treasury skim**. (An optional treasury fee-split exists in the code but is
  disabled on mainnet: the genesis `"randomx": {}` leaves it off.)
- **Validator pinning** (`core/types/validator_pin.go`) — a transaction can pin
  itself to a specific coinbase, making it valid only inside a block mined by
  that exact address.
- **Announcement hardening** (`eth/announce_guard.go`) — guards against
  malicious/premature block and transaction announcements from peers.
- **Multi-node testnet tooling** (`testnet/`) — ready-to-run bootnode/miner/node
  scripts for standing up a small RandomX network.

## Quick start

Requires `librandomx` installed and the pinned Go toolchain (`go1.24.0`; a newer
Go breaks a runtime-internal dependency — see [`mainnet/README.md`](mainnet/README.md)).

```bash
CGO_ENABLED=1 GOTOOLCHAIN=go1.24.0 go build -tags randomx -o build/geth-randomx ./cmd/geth
```

The resulting binary is installed on nodes as `/usr/local/bin/peercash`.

### Mainnet (chainId 620156)

No genesis file to pass and no `--networkid` needed (both auto-derive from the
embedded chainId). Open P2P port 30303 (TCP+UDP) on the firewall of any host you
run this on. A production systemd unit is provided at
[`deploy/peercash-mainnet.service`](deploy/peercash-mainnet.service) (secure by
default: RPC bound to localhost — put a reverse proxy in front for public RPC).

```bash
# A mining node (all supply comes from mining; mine to your own address):
peercash --datadir ~/.peercash-mainnet --port 30303 --nat extip:<this-host-ip> \
  --mine --miner.etherbase 0xYourAddress

# A non-mining full node with JSON-RPC, localhost-only (front with a proxy to expose):
peercash --datadir ~/.peercash-mainnet --port 30303 --nat extip:<this-host-ip> \
  --http --http.addr 127.0.0.1 --http.port 8545 --http.api eth,net,web3 --http.vhosts localhost
```

- `GETH_RANDOMX_THREADS=N` — mining threads (each light-mode thread holds ~256 MiB). Default: one per CPU.
- `GETH_RANDOMX_FULLMEM=1` — fast full-dataset mining (~2.3 GiB RAM), much faster hashing.

Public infrastructure (planned): `rpc.peercash.io` (RPC) and
`explorer.peercash.io` (Blockscout).

### Testnet (chainId 563321)

See [`testnet/README.md`](testnet/README.md) — a separate network for
development and iteration before anything lands on mainnet. Testnet and mainnet
use strictly separate datadirs, services, and chainIds; never mix their configs.

## Security

The RandomX PoW verification and total-difficulty fork-choice paths have been
reviewed (see [`SECURITY_REVIEW.md`](SECURITY_REVIEW.md)). Known gaps before any
real deployment: peer-facing anti-DoS hardening is partial, and there has been
no independent external audit.

## License

Same as upstream go-ethereum: the library code is licensed under the
[GNU Lesser General Public License v3.0](COPYING.LESSER), and the binaries
(`cmd/`) under the [GNU General Public License v3.0](COPYING).
