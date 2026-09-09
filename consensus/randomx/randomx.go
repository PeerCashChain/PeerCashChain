// Copyright 2024 The go-ethereum Authors
// This file is part of the go-ethereum library.
//
// The go-ethereum library is free software: you can redistribute it and/or modify
// it under the terms of the GNU Lesser General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// The go-ethereum library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public License
// along with the go-ethereum library. If not, see <http://www.gnu.org/licenses/>.

// Package randomx implements a proof-of-work consensus engine for go-ethereum
// based on the RandomX algorithm (the CPU-friendly PoW used by Monero). It pairs
// the standard Ethereum EVM/state machine with RandomX sealing, an LWMA
// difficulty retarget and a fixed block reward.
package randomx

import (
	"sync"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/consensus"
	"github.com/ethereum/go-ethereum/core/tracing"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/core/types/bal"
	"github.com/ethereum/go-ethereum/core/vm"
	"github.com/ethereum/go-ethereum/crypto/keccak"
	"github.com/ethereum/go-ethereum/log"
	"github.com/ethereum/go-ethereum/rlp"
	"github.com/holiman/uint256"
)

// PeerCash issuance: Bitcoin-style. Initial reward 1 PEER, halving every
// 10,500,000 blocks, converging to a 21,000,000 PEER cap.
var peerCashInitialReward = uint256.NewInt(1e18) // 1 PEER = 1e18 wei

const peerCashHalvingInterval = 10_500_000 // blocks per halving (~3.3 yr at 10s)

// calcBlockReward returns the block reward at the given height, halving every
// peerCashHalvingInterval blocks. Integer right-shift performs the halving;
// once exhausted it returns zero (21M cap reached, no further issuance).
func calcBlockReward(number uint64) *uint256.Int {
	era := number / peerCashHalvingInterval
	if era >= 64 {
		return uint256.NewInt(0)
	}
	return new(uint256.Int).Rsh(peerCashInitialReward, uint(era))
}

// Mode selects how strictly the engine validates proofs-of-work. The non-normal
// modes exist for testing and development only.
type Mode uint

const (
	ModeNormal   Mode = iota // Full RandomX verification.
	ModeFake                 // Accept any seal, but still apply the other header rules.
	ModeFullFake             // Accept any header without checking anything.
)

// Config holds the runtime configuration of a RandomX engine.
type Config struct {
	PowMode Mode

	// FullMemory enables RandomX "fast" (full-dataset) mode for mining: a single
	// ~2.3 GiB dataset is built once per epoch and shared by all mining threads,
	// giving much faster hashing than the default light (cache-only) mode at the
	// cost of memory. Header verification always uses light mode regardless.
	FullMemory bool

	// Threads is the number of parallel mining threads (and, in light mode, the
	// number of ~256 MiB caches held). Zero or negative means one per CPU. Lower
	// it on memory-constrained hosts.
	Threads int

	// Log is the destination for engine diagnostics. Defaults to the root logger.
	Log log.Logger
}

// RandomX is a proof-of-work consensus engine implementing the RandomX algorithm.
type RandomX struct {
	config Config

	// hasher is the shared RandomX instance used during header verification. It is
	// guarded by lock because VerifyHeaders fans verification out over goroutines.
	// Mining threads do NOT use this instance; they draw from the sealer pool below.
	hasher Hasher
	lock   sync.Mutex

	// sealers is a pool of reusable hashers for the mining threads. Reusing them
	// across blocks means the expensive RandomX cache is only rebuilt when the
	// seed changes (once per epoch) instead of on every Seal. It is filled lazily
	// on first use (see sealerPool in sealer.go).
	sealers    chan Hasher
	sealerInit sync.Once

	closeOnce sync.Once
}

// New creates a full RandomX proof-of-work consensus engine.
func New(config Config) *RandomX {
	if config.Log == nil {
		config.Log = log.Root()
	}
	r := &RandomX{config: config}
	if config.PowMode == ModeNormal {
		// Verification always uses light mode to keep validating nodes lean.
		r.hasher = newHasher(false)
	}
	return r
}

// NewFaker creates a RandomX engine that accepts every seal as valid, while still
// enforcing the remaining header rules. Useful for tests and dev networks.
func NewFaker() *RandomX {
	return &RandomX{config: Config{PowMode: ModeFake, Log: log.Root()}}
}

// NewFullFaker creates a RandomX engine that accepts every header unconditionally.
func NewFullFaker() *RandomX {
	return &RandomX{config: Config{PowMode: ModeFullFake, Log: log.Root()}}
}

// Close releases the resources held by the engine's verification hasher and the
// mining sealer pool.
func (r *RandomX) Close() error {
	r.closeOnce.Do(func() {
		if r.hasher != nil {
			r.hasher.Close()
		}
		// Best-effort drain of the sealer pool. Mining is expected to be stopped
		// before Close is called; any hasher still in flight leaks its C memory
		// until process exit, which is acceptable at shutdown.
		if r.sealers != nil {
			for {
				select {
				case h := <-r.sealers:
					h.Close()
				default:
					return
				}
			}
		}
	})
	return nil
}

// Author implements consensus.Engine, returning the header's coinbase as the
// proof-of-work verified author of the block.
func (r *RandomX) Author(header *types.Header) (common.Address, error) {
	return header.Coinbase, nil
}

// Prepare implements consensus.Engine, initializing the difficulty field of a
// header to conform to the RandomX protocol. The change is done inline.
func (r *RandomX) Prepare(chain consensus.ChainHeaderReader, header *types.Header) error {
	parent := chain.GetHeader(header.ParentHash, header.Number.Uint64()-1)
	if parent == nil {
		return consensus.ErrUnknownAncestor
	}
	header.Difficulty = r.CalcDifficulty(chain, header.Time, parent)
	return nil
}

// treasuryCut returns the given percent of amount, mirroring the split applied
// to transaction fees in core/state_transition.go so block rewards follow the
// same treasury rule.
func treasuryCut(amount *uint256.Int, percent uint64) *uint256.Int {
	cut := new(uint256.Int).Mul(amount, uint256.NewInt(percent))
	return cut.Div(cut, uint256.NewInt(100))
}

// Finalize implements consensus.Engine, crediting the coinbase with the fixed
// block reward, after routing the configured treasury percentage (the same
// cut applied to transaction fees) to TipTreasury. RandomX has no uncles, so
// no uncle rewards are paid. RandomX mines no withdrawals and does not
// populate block access lists itself, so blockAccessIndex and bal (added for
// the Amsterdam fork) are unused here.
func (r *RandomX) Finalize(chain consensus.ChainHeaderReader, header *types.Header, state vm.StateDB, body *types.Body, blockAccessIndex uint32, bal *bal.ConstructionBlockAccessList) {
	reward := calcBlockReward(header.Number.Uint64())
	if !reward.IsZero() {
		if rxCfg := chain.Config().RandomX; rxCfg != nil && rxCfg.TipTreasury != nil {
			if pct := rxCfg.FeePercent(); pct > 0 {
				if cut := treasuryCut(reward, pct); cut.Sign() > 0 {
					reward = new(uint256.Int).Sub(reward, cut)
					state.AddBalance(*rxCfg.TipTreasury, cut, tracing.BalanceIncreaseRewardMineBlock)
				}
			}
		}
		state.AddBalance(header.Coinbase, reward, tracing.BalanceIncreaseRewardMineBlock)
	}
}

// VerifyUncles implements consensus.Engine. RandomX does not support uncles, so
// any block carrying uncles is rejected.
func (r *RandomX) VerifyUncles(chain consensus.ChainReader, block *types.Block) error {
	if r.config.PowMode == ModeFullFake {
		return nil
	}
	if len(block.Uncles()) > 0 {
		return errUnclesUnsupported
	}
	return nil
}

// SeedHash returns the RandomX key (epoch seed) that a header at the given
// block number is sealed and verified under. Exported for remote/external
// mining (e.g. a pool's work RPC), which needs to hand the current seed to
// miners without exposing the rest of the verifier's internals.
func (r *RandomX) SeedHash(chain consensus.ChainHeaderReader, number uint64) []byte {
	return seedHash(chain, number)
}

// SealHash returns the hash of a header prior to it being sealed, i.e. the hash
// over every field except the proof-of-work solution (Nonce and MixDigest).
func (r *RandomX) SealHash(header *types.Header) (hash common.Hash) {
	hasher := keccak.NewLegacyKeccak256()

	enc := []interface{}{
		header.ParentHash,
		header.UncleHash,
		header.Coinbase,
		header.Root,
		header.TxHash,
		header.ReceiptHash,
		header.Bloom,
		header.Difficulty,
		header.Number,
		header.GasLimit,
		header.GasUsed,
		header.Time,
		header.Extra,
	}
	if header.BaseFee != nil {
		enc = append(enc, header.BaseFee)
	}
	rlp.Encode(hasher, enc)
	hasher.Sum(hash[:0])
	return hash
}
