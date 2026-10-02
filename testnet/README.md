# duchain RandomX public testnet

A launchable configuration for the duchain RandomX proof-of-work testnet
(chainId **61102**). These scripts wrap the `geth-randomx` binary; the actual
hosting (servers, public IPs, DNS) is yours to provide.

## 0. Prerequisites
- Go ≥ 1.24 and `librandomx` installed (see `../consensus/randomx/README.md`).
- Open the P2P port (default **30303**, TCP+UDP) on each host's firewall.

## 1. Build
```bash
./build.sh           # produces ../build/geth-randomx
```

## 2. Launch a bootnode (one stable, public host)
```bash
EXTIP=<public-ip> ./bootnode.sh
# In another shell, grab its enode:
../build/geth-randomx attach ~/.duchain-testnet-boot/peercash.ipc --exec admin.nodeInfo.enode
```
Put that enode (with the public IP) into `env.sh` → `BOOTNODES` on every other host.

## 3. Launch miners and nodes (other hosts)
```bash
export BOOTNODES="enode://...@<bootnode-ip>:30303"
EXTIP=<this-host-ip> ETHERBASE=0xYourAddress ./miner.sh   # a mining node
EXTIP=<this-host-ip> ./node.sh                            # an RPC full node
```
A fresh node syncs the chain from peers (header backfill + heaviest-chain fork
choice). New miners need ≥1 announced block to trigger catch-up — fine on a live
network.

## Tuning (node-local env vars)
- `GETH_RANDOMX_THREADS=N` — mining threads (each light-mode thread holds ~256 MiB). Default: one per CPU.
- `GETH_RANDOMX_FULLMEM=1` — fast full-dataset mining (~2.3 GiB RAM), much faster hashing.

## Parameters
- chainId / networkId: **61102** (from "061102" — leading zeros don't exist on integer chain ids)
- Consensus: RandomX PoW, LWMA retarget (target ~12 s/block, window 60)
- Genesis difficulty: `0x800` (self-adjusts via LWMA)
- Block reward: 2 coins, halving every 2,100,000 blocks
- Forks: Homestead…London at genesis; no Shanghai/Cancun (PoW chain, no withdrawals/blobs)

## Optional: treasury fee split
The RandomX engine can route a fixed percentage of each transaction's fees to
treasury addresses. **Opt-in** — if the fields below are absent the miner keeps
100% of the tip and the full base fee is burned (default Ethereum behaviour).

Add to the `randomx` object in `genesis.json` (consensus-critical — must be
**identical on every node**):
```json
"randomx": {
  "tipTreasury": "0x...",        // gets treasuryFeePercent of the priority fee (tip)
  "baseFeeTreasury": "0x...",    // gets treasuryFeePercent of the (else-burned) base fee
  "treasuryFeePercent": 5         // 0-100; zero or omitted disables the split
}
```
- **No implicit default**: omitting `treasuryFeePercent` (or setting it to 0)
  means no cut is taken, even if treasury addresses are set. Values above 100
  are clamped to 100.
- The miner/coinbase receives the remaining (100 − percent)% of the tip.
- The remaining base fee keeps being burned (EIP-1559).
- Either address may be set independently (set only `tipTreasury` to split just the tip).
- Validated end-to-end: with percent 5, each treasury receives exactly 5% of its pot.

## ⚠️ This is a TESTNET, not a mainnet
It has **not** been security-audited, the network hardening is partial (no
anti-DoS peer scoring / announcement rate-limiting yet), and the low bootstrap
difficulty makes early 51% trivial. Do not attach real economic value. See
`../SECURITY_REVIEW.md` for the current security posture and open risks.
