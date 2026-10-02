# CLAUDE.md - PeerCash Chain / Node

Context for Claude Code working in this repo. Read this fully before making changes.
It encodes decisions and hard-won lessons that are NOT obvious from the code.

> Items marked **RULE** are hard constraints - do not violate them.
> Items marked `<FILL IN>` need the human to complete them.

---

## What PeerCash is

PeerCash is a **sovereign, CPU-mineable, EVM-compatible Layer 1** blockchain. It is a
**go-ethereum (geth) fork** with **RandomX proof-of-work** for CPU-friendly, ASIC-resistant
mining. The thesis: sound money you mine yourself on a normal computer - fair launch, no
premine, no VC allocation, 21,000,000 PEER hard cap.

The whole value proposition rests on two things at once:
1. **It's a real independent chain** - own genesis, own network, own rules.
2. **It's fully EVM-compatible** - MetaMask, ethers.js, Foundry, Blockscout, and every
   standard EVM tool work with it out of the box.

Both matter. Do not do anything that sacrifices #2 for a feeling of more #1 (see the
rename RULE below - this is the single most important constraint in this file).

### Chain parameters
- **Consensus:** RandomX PoW
- **Block time:** ~10s
- **Supply cap:** 21,000,000 PEER, no premine (genesis alloc MUST be empty)
- **Native currency:** PEER, 18 decimals
- **Testnet chainId:** 563321
- **Mainnet chainId:** 620156 (claimed/verified free in the ethereum-lists registry)
- Keep testnet and mainnet strictly separate - never let configs cross.

---

## CRITICAL RULES (the landmines)

### RULE 1 - Do NOT rename the EVM / protocol layer. Brand only the user-facing layer.
This is the big one. It is tempting to rename every "eth" to "peer" to make the chain feel
more fully PeerCash. **Most of that is forbidden because it breaks EVM compatibility and/or
cuts us off from upstream security patches.**

- **NEVER rename JSON-RPC methods** (`eth_call`, `eth_getBalance`, `eth_blockNumber`,
  `eth_sendRawTransaction`, etc.). These are the EVM standard. Renaming them to `peer_*`
  breaks MetaMask, ethers.js, Foundry, Blockscout, wallets, and every dApp. This destroys
  the entire value proposition. Absolute do-not-touch.
- **NEVER rename EVM internals** - the `eth` package, tx/account/state types, Wei/Gwei
  units, core geth package names. This introduces bugs and makes it impossible to merge
  upstream go-ethereum security fixes (which we WANT - see RULE 2).
- **DO brand the user-facing layer only:** binary name (`peercash`), datadir
  (`.peercash*`), native currency display (PEER), client version / node identity string
  (e.g. `PeerCash/vX` not `Geth/vX`), CLI help text, network name strings, docs/README.
- **Do NOT** do cosmetic internal renames (variables, comments) - pure cost (upstream
  merge conflicts, churn, bug risk), zero user-visible benefit.

The chain is sovereign because of its genesis, chainId, and network - NOT because internal
variables say "peer". A user sees PeerCash from the branding layer alone.

### RULE 2 - Preserve upstream-mergeability with go-ethereum.
Geth ships security patches we need. Keep our diff from upstream as small and surgical as
possible (RandomX consensus, branding, chain params). Every gratuitous change makes merging
critical upstream fixes harder. Before large refactors, ask: does this make it harder to
pull an upstream security patch? If yes, don't.

### RULE 3 - This chain's fee market needs explicit gas settings.
The chain is EIP-1559 with a very low base fee (~7 wei). Foundry / tooling auto fee
estimation produces **un-mineable transactions** on this chain. For any deploy or scripted
tx, ALWAYS set fees explicitly, e.g.:
`--priority-gas-price 1gwei --gas-price 2gwei`
Never rely on bare auto-estimation or a lone `--gas-price`. (This cost real debugging time;
do not rediscover it.)

### RULE 4 - Genesis is irreversible. Test before committing.
Once mainnet is live and real blocks are mined, genesis cannot be changed without forking
the whole chain. Before mainnet genesis is finalized:
- Verify **deterministic genesis hash** (init from genesis.json many times on clean
  datadirs -> identical hash every time).
- Verify **clean start reliably** (loop init+start many times, always healthy).
- Verify **multi-node agreement** (2+ nodes from the same genesis agree on hash and peer).
- Verify **mining from block 0** at sane initial difficulty.
- Verify **empty alloc** (no pre-funded accounts - this is the fair-launch guarantee).
- Then **freeze the genesis.json and record its SHA256** - treat it as immutable.

### RULE 5 - Files edited/pasted onto the server must be pure ASCII.
Config/scripts are often pasted over SSH; non-ASCII bytes (em-dashes, smart quotes) get
corrupted in transit and cause encoding failures. Keep server-bound files ASCII-only.

### RULE 6 - Human-gated decisions. Propose and script; do not autonomously execute.
Claude Code is great for buildable/testable work (test scripts, docs, deploy scripts,
config scaffolding). But the following stay with the human, verified - NOT delegated:
- Final genesis parameters (chainId, difficulty, alloc, reward schedule)
- Anything touching keys, security, or custody
- Launch timing and the launch sequence
- Anything irreversible on mainnet
For these, propose options and scripts for human review; do not run them unprompted.

---

## Repo structure, build, run

> `<FILL IN>` these from the actual repo - do not guess when running commands.

- **Repo:** `<FILL IN repo path on disk, e.g. /root/peercash-node>` (GitHub: `<FILL IN, private for now>`)
- **Layout:** `testnet/` and `mainnet/` are SIBLINGS (mainnet is NOT nested inside testnet).
  Keep their configs strictly separate - no shared datadir, service, or port. This
  separation is deliberate: a config mistake in testnet is free, in mainnet it can be
  irreversible, so they must not share a working directory or bleed values.
- **Is it:** `<FILL IN: full geth fork we maintain, or thin config layer over geth?>`
- **Already renamed:** `<FILL IN: binary? datadir? currency? client version? - so we don't re-do or miss>`
- **Build:** `<FILL IN build command, e.g. make peercash / go build ./cmd/...>`
- **Binary output:** `<FILL IN, e.g. /usr/local/bin/peercash>`
- **Genesis file(s):** `<FILL IN path to testnet + mainnet genesis.json>`

### Node run reference (testnet, current)
Binary: `/usr/local/bin/peercash` (verify), run as user `peercash`, datadir
`/home/peercash/.peercash-testnet`, archive mode, chainId 563321.
Key flags in use (from the running service): HTTP on `0.0.0.0:8545` with
`--http.api eth,net,web3,debug,txpool`, WS on `0.0.0.0:8546` with `--ws.api eth,net,web3`.
Systemd unit: `peercash-testnet.service` at `/etc/systemd/system/`.

Mainnet will mirror this with chainId 620156, mainnet genesis, and mainnet domains
(`rpc.peercash.io`, `explorer.peercash.io`). Keep them on separate datadirs/services.

---

## Infrastructure (where things live)

Primary box ("MFPurrs"), Ubuntu, public IP `167.71.186.249`:
- Node service: `peercash-testnet.service` (datadir `/home/peercash/.peercash-testnet`)
- Website root: `/var/www/peercash/` (peercash.io; also `/testswap/`, `/testpool/` DEX UIs)
- Explorer (Blockscout): `/opt/blockscout/` (Docker Compose; sc-verifier enabled)
- DEX (Foundry): `/root/peercash-dex/` (separate repo/skill from this node repo)
- IPFS daemon: systemd `ipfs` service, public IP :4001 - hosts the chain icon CID
  `Qmd4HwLcbLvPia3Kc9w2KLQMnn48EJf1VaDhx3vzSMCPzS` (keep it running; permanent icon host)
- nginx config: `/etc/nginx/sites-available/peercash.io`

Mainnet fleet (planned, not built): 2 RPC/bootnode behind a VIP (`rpc.peercash.io`,
health-checked on sync status) + 1 miner; explorer separate; existing box stays testnet.
Add swap to every box (the testnet box ran with zero swap / near-zero free RAM, which
caused silent OOM kills - do not repeat).

---

## Conventions

- Pure ASCII in anything server-bound (RULE 5).
- Small, surgical diffs from upstream geth (RULE 2).
- Testnet (563321) and mainnet (620156) configs never mixed.
- Version node releases + publish SHA256 checksums; genesis published + hash-verifiable.
- Transparency is the ethos: prefer public, verifiable artifacts (fair-launch credibility).

---

## Current state (update as it moves)

- Testnet: live, mining, with website + explorer + DEX (swap/pool) deployed.
- Mainnet: in planning. chainId 620156 claimed; chain icon created + IPFS-hosted + verified;
  ethereum-lists registry PR drafted (gated on live mainnet RPC).
- Full mainnet plan: see `PEERCASH-MAINNET-CHECKLIST.md`.
- Next likely work: mainnet genesis (test per RULE 4), bootnodes, RPC standup.

Related docs: `PEERCASH-MAINNET-CHECKLIST.md` (the phased launch runbook).
