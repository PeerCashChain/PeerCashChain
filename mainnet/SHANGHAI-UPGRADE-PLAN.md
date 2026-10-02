# PeerCash Shanghai Upgrade Plan (first network hard fork)

Status: PLAN ONLY -- no code changed. Execute when coordinating the first network
hard fork, AFTER the mainnet fleet exists. Mainnet launches on London with the
frozen genesis UNCHANGED; Shanghai is activated later as a scheduled, timestamp-
based hard fork.

## Decisions confirmed
- Launch proceeds on **London** (frozen mainnet genesis stays byte-identical;
  genesis hash 0x40574acbb80c928e5484f9d22672e85f2cb168235a0864c10e8f35bd57a55ff1,
  SHA256 233bec9c33063535bb40e1672aff61271e88128d9aa5fbbc36c5a12fee845385).
- **Shanghai is the FIRST hard fork, post-fleet.** It is NOT a genesis change --
  it is activated by setting a future `ShanghaiTime` in the chain config. The
  genesis block (number 0, London rules) is untouched.

## Scope
INCLUDE (Shanghai EVM + consensus-safe parts):
- EIP-3855 PUSH0 opcode (the main tooling/compatibility win: modern Solidity /
  Foundry output uses PUSH0).
- EIP-3651 warm COINBASE.
- EIP-3860 limit and meter initcode.
- EIP-4895 withdrawals -- but PeerCash has no beacon chain, so the withdrawals
  list is ALWAYS empty. The only visible effect is the header carrying
  withdrawalsRoot = EmptyWithdrawalsHash.

EXCLUDE (Cancun and later -- separate, harder, out of scope here):
- EIP-4844 blobs, EIP-4788 beacon block root, EIP-1153/5656/6780 (Cancun EVM),
  and anything requiring a consensus layer. The engine must KEEP rejecting
  ExcessBlobGas / BlobGasUsed / ParentBeaconRoot / SlotNumber header fields.

## Key finding: most of Shanghai already activates off config.IsShanghai
This fork is modern go-ethereum (v1.17.4). The Shanghai implementation already
exists and is gated on the timestamp-based `(*ChainConfig).IsShanghai(num, time)`
(params/config.go:853). The following already do the correct thing once Shanghai
is active, with NO change needed:

- EVM opcodes: PUSH0 is wired via `enable3855` (core/vm/eips.go:228) and gated on
  `rules.IsShanghai` (core/vm/evm.go:166, core/vm/common.go:34). EIP-3651/3860
  likewise activate on IsShanghai.
- Miner assembly: miner/worker.go (~lines 193-207) already checks IsShanghai and,
  when active, sets an empty-but-non-nil withdrawals list
  (`body.Withdrawals = make([]*types.Withdrawal, 0)`); before Shanghai it requires
  withdrawals to be nil.
- Block construction: core/types/block.go NewBlock (~lines 278-287) sets
  `header.WithdrawalsHash = &EmptyWithdrawalsHash` for an empty withdrawals list.
- Body validation: core/block_validator.go ValidateBody (~lines 74-85) already
  enforces "withdrawals present after Shanghai, root matches; absent before."
- Fork identity: core/forkid gatherForks (core/forkid/forkid.go:242) already
  gathers timestamp forks, so setting ShanghaiTime changes the forkid at the fork
  boundary automatically.

Because of this, the actual consensus-engine delta is TINY -- a single conditional
in the RandomX header check.

## The one real blocker (and the fix)
File: `consensus/randomx/consensus.go`, func `verifyHeader` (~lines 167-179).
Today it UNCONDITIONALLY rejects any post-merge header field, including:
```
case header.WithdrawalsHash != nil:
    return fmt.Errorf("invalid withdrawalsHash: have %x, expected nil", header.WithdrawalsHash)
```
This directly contradicts Shanghai (which requires withdrawalsRoot in the header).

Change (make the withdrawalsHash rule Shanghai-aware; keep rejecting Cancun+):
```
if chain.Config().IsShanghai(header.Number, header.Time) {
    // Shanghai active: PoW chain has no real withdrawals, so the root must be
    // present and exactly the empty-withdrawals root.
    if header.WithdrawalsHash == nil {
        return errors.New("missing withdrawalsHash after Shanghai")
    }
    if *header.WithdrawalsHash != types.EmptyWithdrawalsHash {
        return fmt.Errorf("invalid withdrawalsHash: have %x, expected empty-withdrawals root %x",
            *header.WithdrawalsHash, types.EmptyWithdrawalsHash)
    }
} else if header.WithdrawalsHash != nil {
    return fmt.Errorf("invalid withdrawalsHash before Shanghai: have %x, expected nil", header.WithdrawalsHash)
}
// Cancun and later remain unsupported -- keep rejecting these unconditionally:
switch {
case header.ExcessBlobGas != nil:   return ...
case header.BlobGasUsed != nil:     return ...
case header.ParentBeaconRoot != nil:return ...
case header.SlotNumber != nil:      return ...
}
```
Add the `types` import if not already present in this file.

## Change list (by file / function)

1. params/config.go -- `MainnetChainConfig`
   - Add `ShanghaiTime: newUint64(<FORK_UNIX_TIMESTAMP>),` (a future time, agreed
     during fork coordination). Leave CancunTime/PragueTime/etc. nil.
   - Do the same on the testnet config first (testnet/genesis.json config and/or
     the compiled testnet config) to rehearse the fork on testnet before mainnet.
   - Genesis files are NOT changed. ShanghaiTime is a config/activation field, not
     a genesis parameter; the genesis block stays London.

2. consensus/randomx/consensus.go -- `verifyHeader`
   - Apply the Shanghai-aware withdrawalsHash rule above. This is the only
     consensus-critical code change.

3. consensus/randomx/randomx.go -- VERIFY ONLY (likely no change)
   - `Finalize` already notes it mines no withdrawals; the empty withdrawals list
     credits nobody, so no reward/withdrawal change is needed.
   - `SealHash` (~line 220) does NOT include withdrawalsRoot. Since the root is a
     constant (EmptyWithdrawalsHash) for every post-Shanghai block, this is safe
     and does not weaken PoW. DECISION: leave SealHash unchanged (keeps the seal
     input stable; matches how Ethereum never sealed over withdrawalsRoot).

4. Block production / assembly -- VERIFY ONLY (no change expected)
   - miner/worker.go already fills empty withdrawals post-Shanghai; confirm the
     RandomX seal/commit path builds the block via types.NewBlock with that body
     so header.WithdrawalsHash is populated before the sealed block is verified.
   - core/state_processor.go: confirm block processing handles an empty
     withdrawals list cleanly (empty loop -> no state change). Expected: no change.

5. core/forkid -- VERIFY + TEST REWRITE
   - gatherForks already includes ShanghaiTime; the forkid changes automatically
     at the fork boundary. No forkid.go change expected.
   - core/forkid/forkid_test.go is currently inherited Ethereum baggage (asserts
     Ethereum's Shanghai/Cancun/Prague checksums; already failing pre-fork).
     Rewrite TestCreation/TestValidation for PeerCash's real two-era schedule:
     London-at-genesis era, then Shanghai-at-ShanghaiTime era. Expected checksums
     must be regenerated from PeerCash's MainnetChainConfig + frozen genesis hash.

6. EVM -- NO CHANGE
   - PUSH0 / warm coinbase / initcode limit activate via IsShanghai. Nothing to do
     beyond setting ShanghaiTime.

## Testing plan
- Unit (consensus): add RandomX engine tests that, with Shanghai active,
  (a) ACCEPT a header whose WithdrawalsHash == EmptyWithdrawalsHash,
  (b) REJECT a header with WithdrawalsHash == nil,
  (c) REJECT a header with a non-empty withdrawalsRoot,
  (d) still REJECT ExcessBlobGas/BlobGasUsed/ParentBeaconRoot/SlotNumber.
  And with Shanghai NOT active, REJECT any non-nil WithdrawalsHash (unchanged).
- Unit (forkid): rewritten forkid test passes for both eras.
- EVM: a contract using PUSH0 deploys and runs only at/after ShanghaiTime and
  reverts/doesn't exist before it (sanity that the gate flips on time).
- Integration: extend mainnet/test-genesis.sh (or a new script) to mine across a
  near-future ShanghaiTime on a scratch datadir and confirm:
  - blocks before ShanghaiTime have no withdrawalsRoot,
  - blocks at/after have withdrawalsRoot == EmptyWithdrawalsHash,
  - the node keeps producing and validating blocks across the boundary,
  - two nodes from the same config agree across the fork (no split).
- Full suite: `GOTOOLCHAIN=go1.24.0 go test ./core/... ./consensus/...` green,
  except the known-unrelated blobpool blob-tx tests (no Cancun -- keep skipped).

## Deployment / coordination (hard-fork mechanics)
- Pick ShanghaiTime far enough out that 100% of the fleet + all miners upgrade
  BEFORE it. A node still running the old binary at ShanghaiTime will reject the
  new (withdrawalsRoot-bearing) blocks and fork off -> chain split. This is why it
  waits until the fleet exists and can be coordinated.
- Sequence: ship the new binary -> everyone upgrades and restarts (no resync; it
  is the same chain/genesis) -> fork activates automatically at ShanghaiTime.
- Rehearse on testnet first with a near-term ShanghaiTime; confirm the boundary,
  then schedule mainnet.
- Publish the ShanghaiTime and the new binary SHA256 ahead of time (same
  fair-launch transparency as genesis).

## Rollback / safety
- Before ShanghaiTime, the new binary behaves exactly like the old one (the only
  behavioral change is gated on IsShanghai), so deploying early is safe.
- If a problem is found before ShanghaiTime, ship a build that moves ShanghaiTime
  later (or unsets it) and have the fleet upgrade -- no chain damage since the fork
  never activated. After ShanghaiTime passes on mainnet it is irreversible without
  a coordinated rollback fork; treat the final ShanghaiTime as a commitment.

## Explicitly NOT in this upgrade
- Cancun (EIP-4844 blobs, EIP-4788 beacon root, EIP-1153/5656/6780). These bundle
  consensus-layer machinery a PoW chain lacks and would require decoupling that
  increases divergence from upstream (raising RULE 2 merge cost). If the Cancun
  EVM opcodes (transient storage, MCOPY) are later wanted without blobs, that is a
  separate plan: gate the Cancun EVM EIPs on while neutralizing 4844 (zero blob
  capacity) and 4788 (no beacon root), and extend the verifyHeader rules again.

## Open decisions (for fork coordination)
- Exact ShanghaiTime (mainnet and testnet).
- Whether to also rebrand/clean the forkid test as part of this change or earlier.
- Whether to bundle any other small EVM-compat improvements into the same fork to
  avoid multiple coordinated upgrades.
