# PeerCash RandomX MAINNET (chainId 620156)

Launch configuration for the PeerCash RandomX proof-of-work **mainnet**. This
directory is a SIBLING of `testnet/` and must never share a datadir, nodekey,
systemd service, or (if co-located) P2P port with testnet.

> STATUS: SCAFFOLDING / PROPOSAL. The genesis below is NOT frozen. Per RULE 4 the
> genesis is a human-gated, irreversible decision: you run `test-genesis.sh`,
> verify it, then freeze `genesis.json` and record its SHA256. Until then every
> value here is a proposal for review.

## Files
- `genesis.json` -- proposed mainnet genesis (chainId 620156, empty alloc, no treasury split).
- `test-genesis.sh` -- genesis reliability test (determinism, empty alloc, mines block 1).
- `../deploy/peercash-mainnet.service` -- systemd unit template (fill REPLACE_ placeholders).

## Proposed parameters
- chainId / networkId: **620156** (claimed/verified free in the ethereum-lists registry).
- Consensus: RandomX PoW with LWMA retarget (target **12 s/block**, window **60**).
- Genesis difficulty: **0x400** (1024) -- calibrated for ~12 s blocks at single-box
  CPU hashrate; see "Difficulty" below.
- Block reward: **1 PEER**, halving every **10,500,000** blocks, converging to the
  **21,000,000 PEER** hard cap. (Enforced in `consensus/randomx`, chain-wide.)
- Fees: full EIP-1559 base-fee burn, **no treasury skim** (`"randomx": {}`).
- Native currency: PEER (18 decimals).
- Alloc: **empty** -- no premine, no VC allocation (fair-launch guarantee).
- Forks: Homestead..London at genesis; no Shanghai/Cancun (PoW chain, no
  withdrawals/blobs).

This genesis agrees with the binary's compiled-in `MainnetChainConfig`
(`params/config.go`): both declare chainId 620156 and no fee split, so a node
behaves identically whether launched from this `genesis.json` or the compiled-in
default.

## Difficulty (why 0x400)
During the first 60 blocks the LWMA retarget has no window yet and simply holds
the genesis difficulty, so **block 1 mines at exactly the genesis difficulty**;
only from block 61 does the retarget steer toward the 12 s target. The genesis
value therefore sets the solve time of the first ~60 blocks.

`0x400` (1024) is the **calibrated** value: on a single 2-core box, LWMA settled at
~1000 for 12 s blocks, so the genesis difficulty is set to the clean round value
0x400 at that calibrated point. This replaces an earlier `0x100` (256) workaround,
which was chosen while mining was mis-configured (sealing to a placeholder
etherbase never produced a block, which looked like a difficulty problem); with a
real miner account, 256 produced ~3 s blocks and LWMA raised difficulty ~4x to
reach the 12 s target. Starting at 0x400 hits steady state from block ~61 without
a warmup ramp. The error is self-correcting either way: set it too low and the
first blocks mine fast until LWMA raises it; too high and the warmup is slow until
LWMA lowers it -- neither is dangerous. Final call is yours.

## Building from source (reproducible)
Fair-launch credibility depends on anyone being able to build and verify the
binary from source, so the toolchain is pinned:
- **Go toolchain: `go1.24.0`.** `go.mod` declares `go 1.24.0`. A newer local Go
  (e.g. 1.27.x) does NOT work -- the `github.com/cockroachdb/swiss` dependency
  uses runtime internals that changed after 1.24, so the build fails with
  `undefined: hashFn / fastrand64 / getRuntimeHasher`. `GOTOOLCHAIN=auto` only
  upgrades, never downgrades, so you must pin it explicitly:
  ```bash
  GOTOOLCHAIN=go1.24.0 go build -o build/geth-randomx -tags randomx ./cmd/geth
  ```
- **`-tags randomx` requires `librandomx`** installed (the production cgo RandomX
  binding; see `consensus/randomx/README.md`). Without it, use the default build
  (pure-Go stub) only for compile checks, not for mining/validation.
- Verify the binary: `build/geth-randomx version`.

(Note: a `toolchain go1.24.0` line in `go.mod` does NOT fix this -- a toolchain
directive is a floor, not a cap, so a newer local Go under `GOTOOLCHAIN=auto` is
still used (and it also broke `go build` here). The reliable pin is the
`GOTOOLCHAIN=go1.24.0` env var shown above, enforced in build scripts/CI. Full
automatic reproducibility would require vendoring a swiss version compatible with
newer Go -- out of scope.)

## Launch (after genesis is verified and frozen)
One-time init (datadir must be empty), then run under systemd:
```bash
/usr/local/bin/peercash --datadir /home/peercash/.peercash-mainnet init /path/to/mainnet/genesis.json
# edit ../deploy/peercash-mainnet.service: set REPLACE_MAINNET_PUBLIC_IP and
# REPLACE_MAINNET_ETHERBASE_ADDRESS, install to /etc/systemd/system/, then:
sudo systemctl enable --now peercash-mainnet
```

## Still to supply (fleet not built yet -- placeholders)
- Bootnodes / static enodes for the mainnet fleet (do NOT reuse the testnet enode
  at 167.71.186.249; `params/bootnodes.go` still points `MainnetBootnodes` /
  `MainnetStaticNodes` there -- update once the mainnet fleet exists).
- Public IP (`REPLACE_MAINNET_PUBLIC_IP`) and miner etherbase
  (`REPLACE_MAINNET_ETHERBASE_ADDRESS`) in the service file.
- Domains: rpc.peercash.io / ws / explorer.peercash.io.

## Genesis verification (FROZEN -- immutable)
The mainnet genesis is frozen. Any node on the real PeerCash mainnet MUST produce
exactly these values; if yours differ, you are NOT on the real chain.

| Artifact | Value |
| --- | --- |
| chainId | `620156` |
| Difficulty | `0x400` (1024) |
| extraData | empty (`0x`) |
| alloc | empty (no premine) |
| **Genesis block hash** | `0x40574acbb80c928e5484f9d22672e85f2cb168235a0864c10e8f35bd57a55ff1` |
| **`genesis.json` SHA256** | `233bec9c33063535bb40e1672aff61271e88128d9aa5fbbc36c5a12fee845385` |

Verify your copy of this file:
```bash
sha256sum mainnet/genesis.json
# expect: 233bec9c33063535bb40e1672aff61271e88128d9aa5fbbc36c5a12fee845385
```
Verify the live chain's genesis block hash matches:
```bash
peercash attach <ipc> --exec 'eth.getBlock(0).hash'
# expect: 0x40574acbb80c928e5484f9d22672e85f2cb168235a0864c10e8f35bd57a55ff1
```
The same hash is pinned in the binary as `params.MainnetGenesisHash`
(`params/config.go`) and matches `DefaultGenesisBlock()`.

## Re-verify from scratch (RULE 4)
```bash
./test-genesis.sh        # determinism + empty alloc + mines block 1 at genesis difficulty
```
