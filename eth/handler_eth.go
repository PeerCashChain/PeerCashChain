// Copyright 2020 The go-ethereum Authors
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

package eth

import (
	"errors"
	"fmt"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/consensus/randomx"
	"github.com/ethereum/go-ethereum/core"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto/kzg4844"
	"github.com/ethereum/go-ethereum/eth/protocols/eth"
	"github.com/ethereum/go-ethereum/log"
	"github.com/ethereum/go-ethereum/p2p"
	"github.com/ethereum/go-ethereum/p2p/enode"
	"github.com/ethereum/go-ethereum/params"
)

// ethHandler implements the eth.Backend interface to handle the various network
// packets that are sent as replies or broadcasts.
type ethHandler handler

func (h *ethHandler) Chain() *core.BlockChain { return h.chain }
func (h *ethHandler) TxPool() eth.TxPool      { return h.txpool }
func (h *ethHandler) BlobPool() eth.BlobPool  { return h.blobpool }

// RunPeer is invoked when a peer joins on the `eth` protocol.
func (h *ethHandler) RunPeer(peer *eth.Peer, hand eth.Handler) error {
	return (*handler)(h).runEthPeer(peer, hand)
}

// PeerInfo retrieves all known `eth` information about a peer.
func (h *ethHandler) PeerInfo(id enode.ID) interface{} {
	if p := h.peers.peer(id.String()); p != nil {
		return p.info()
	}
	return nil
}

// AcceptTxs retrieves whether transaction processing is enabled on the node
// or if inbound transactions should simply be dropped.
func (h *ethHandler) AcceptTxs() bool {
	return h.synced.Load()
}

// Handle is invoked from a peer's message handler when it receives a new remote
// message that the handler couldn't consume and serve itself.
func (h *ethHandler) Handle(peer *eth.Peer, packet eth.Packet) error {
	// Consume any broadcasts and announces, forwarding the rest to the downloader
	switch packet := packet.(type) {
	case *eth.NewBlockPacket:
		return h.handleNewBlock(peer, packet.Block)

	case *eth.NewPooledTransactionHashesPacket72:
		hashes, err := h.txFetcher.Notify(peer.ID(), packet.Types, packet.Sizes, packet.Hashes)
		if err != nil {
			return err
		}
		if len(hashes) != 0 {
			return h.blobFetcher.Notify(peer.ID(), hashes, packet.Mask)
		}
		return nil

	case *eth.NewPooledTransactionHashesPacket71:
		_, err := h.txFetcher.Notify(peer.ID(), packet.Types, packet.Sizes, packet.Hashes)
		return err

	case *eth.TransactionsPacket:
		txs, err := packet.Items()
		if err != nil {
			return fmt.Errorf("Transactions: %v", err)
		}
		if err := handleTransactions(peer, txs, true); err != nil {
			return fmt.Errorf("Transactions: %v", err)
		}
		return h.txFetcher.Enqueue(peer.ID(), peer.Version(), txs, false)

	case *eth.PooledTransactionsPacket:
		txs, err := packet.List.Items()
		if err != nil {
			return fmt.Errorf("PooledTransactions: %v", err)
		}
		if err := handleTransactions(peer, txs, false); err != nil {
			return fmt.Errorf("PooledTransactions: %v", err)
		}
		return h.txFetcher.Enqueue(peer.ID(), peer.Version(), txs, true)

	case *eth.CellsResponse:
		outer, err := packet.Cells.Items()
		if err != nil {
			return fmt.Errorf("Cells: %v", err)
		}
		cells := make([][]kzg4844.Cell, len(outer))
		for i := range outer {
			if outer[i].Len() > params.BlobTxMaxBlobs*kzg4844.CellsPerBlob {
				return fmt.Errorf("Cells: cells per tx exceeded the possible maximum")
			}
			if cells[i], err = outer[i].Items(); err != nil {
				return fmt.Errorf("Cells: %v", err)
			}
		}
		return h.blobFetcher.Enqueue(peer.ID(), packet.Hashes, cells, packet.Mask)

	default:
		return fmt.Errorf("unexpected eth packet type: %T", packet)
	}
}

// handleNewBlock imports a block propagated by a peer on a RandomX proof-of-work
// network. Import failures (e.g. an unknown ancestor because we're behind) are
// logged but not returned, so the peer is not disconnected over them. A
// successful import fires a ChainHeadEvent, which the broadcast loop relays on.
func (h *ethHandler) handleNewBlock(peer *eth.Peer, block *types.Block) error {
	if h.chain.Config().RandomX == nil {
		// Ignore block gossip on non-PoW networks.
		return nil
	}
	if block == nil {
		return nil
	}
	// Rate-limit announcements per peer before doing any work at all. Excess
	// messages are ignored; a peer flooding far past the limit is banned and
	// dropped (returning an error disconnects it).
	if ok, hard := h.guard.allowAnnounce(peer.ID()); !ok {
		if hard {
			h.guard.ban(peer.ID())
			return errors.New("NewBlock announcement flood")
		}
		log.Debug("Throttling block announcements", "peer", peer.ID())
		return nil
	}
	header := block.Header()
	// Cheap sanity gate before spending any hashing effort on the announcement.
	if header.Time > uint64(time.Now().Unix()+15) {
		log.Debug("Ignoring future-dated propagated block", "number", block.NumberU64(), "peer", peer.ID())
		return nil
	}
	// Authenticate the announcement with its own PoW seal whenever the epoch key
	// is derivable from our local chain, so a peer cannot trigger imports or
	// backfills for free. A bogus seal is a protocol violation: ban the peer and
	// return the error to drop it. When the seed block is beyond our head the
	// seal can't be checked yet; the backfill import then validates everything
	// block by block.
	if pow, ok := h.chain.Engine().(*randomx.RandomX); ok {
		switch err := pow.VerifySeal(h.chain, header); {
		case err == nil, errors.Is(err, randomx.ErrUnknownSeedBlock):
		default:
			h.guard.ban(peer.ID())
			return fmt.Errorf("propagated block #%d [%x] has invalid PoW seal: %w", block.NumberU64(), block.Hash(), err)
		}
	}
	// When the parent is known, the header can be validated in full right now —
	// including the declared difficulty against the LWMA retarget — closing the
	// "cheap minimum-difficulty header" hole left by the seal-only gate above.
	// Failure is likewise a protocol violation: ban and drop.
	parentKnown := h.chain.GetHeader(header.ParentHash, header.Number.Uint64()-1) != nil
	if parentKnown {
		if err := h.chain.Engine().VerifyHeader(h.chain, header); err != nil {
			h.guard.ban(peer.ID())
			return fmt.Errorf("propagated block #%d [%x] has invalid header: %w", block.NumberU64(), block.Hash(), err)
		}
	}
	// If the block is more than one ahead of our head, we're missing its
	// ancestors. Backfill the gap from this peer instead of failing the import;
	// the announced block will land once we've caught up.
	head := h.chain.CurrentBlock().Number.Uint64()
	if block.NumberU64() > head+1 {
		h.startBackfill(peer, block.NumberU64())
		return nil
	}
	if _, err := h.chain.InsertChain(types.Blocks{block}); err != nil {
		// With the header fully validated above (parent known), an import failure
		// means forged content (bad body/state): count it against the peer. With
		// an unknown parent the failure can be benign (we're mid-reorg or behind).
		if parentKnown && h.guard.strike(peer.ID()) {
			h.guard.ban(peer.ID())
			return fmt.Errorf("repeated invalid propagated blocks, last: %w", err)
		}
		log.Debug("Failed to import propagated block", "number", block.NumberU64(), "hash", block.Hash(), "err", err)
		return nil
	}
	log.Info("Imported propagated block", "number", block.NumberU64(), "hash", block.Hash(), "peer", peer.ID())
	return nil
}

// startBackfill launches the RandomX gap-sync toward target in the background,
// unless one is already running.
func (h *ethHandler) startBackfill(peer *eth.Peer, target uint64) {
	if !h.backfilling.CompareAndSwap(false, true) {
		return
	}
	go func() {
		defer h.backfilling.Store(false)
		h.backfill(peer, target)
	}()
}

// backfill fetches and imports the missing blocks between our head and target by
// requesting headers from the peer in batches. Our blocks carry no transactions
// or uncles, so they are reconstructed from headers alone; tx-bearing chains
// would additionally need RequestBodies here.
func (h *ethHandler) backfill(peer *eth.Peer, target uint64) {
	const batch = 128

	// Find where our chain and the peer's chain last agree, so divergent forks
	// (not just a strict prefix) are handled correctly.
	ancestor := h.findCommonAncestor(peer, target)
	log.Info("Starting RandomX chain backfill", "peer", peer.ID(), "target", target, "ancestor", ancestor)

	next := ancestor + 1
	for next <= target {
		headers, err := h.fetchHeaders(peer, next, batch)
		if err != nil || len(headers) == 0 {
			log.Debug("RandomX backfill stopped", "from", next, "got", len(headers), "err", err)
			return
		}
		blocks := h.assembleBlocks(peer, headers)
		// Insert one block at a time so that each block's full LWMA ancestor
		// window (difficultyWindow = 60 headers) is committed to the DB before
		// the next header is validated. InsertChain calls VerifyHeaders on the
		// entire slice before writing anything, so batching N > 1 blocks means
		// chain.GetHeader() returns nil for in-flight ancestors, causing the
		// LWMA fallback to produce a wrong difficulty and reject valid blocks.
		for _, block := range blocks {
			if _, err := h.chain.InsertChain(types.Blocks{block}); err != nil {
				// We asked this peer for its canonical chain from a common ancestor,
				// so consensus-invalid data here is the peer's fault: strike it, and
				// ban + disconnect on repeat offence. (Network errors above, by
				// contrast, are not counted.)
				if h.guard.strike(peer.ID()) {
					h.guard.ban(peer.ID())
					peer.Disconnect(p2p.DiscSubprotocolError)
				}
				log.Debug("RandomX backfill import failed", "block", block.NumberU64(), "err", err)
				return
			}
		}
		last := blocks[len(blocks)-1].NumberU64()
		log.Info("RandomX backfill progress", "imported", next, "to", last, "target", target)
		next = last + 1
	}
	log.Info("RandomX chain backfill complete", "head", h.chain.CurrentBlock().Number.Uint64())
}

// assembleBlocks turns a batch of headers into full blocks. For headers with a
// non-empty body it fetches the bodies from the peer; empty blocks (the common
// case for this chain) are reconstructed from the header alone. On any body
// retrieval problem it falls back to headers-only, which is correct for empty
// blocks and simply lets InsertChain reject if a body was actually required.
func (h *ethHandler) assembleBlocks(peer *eth.Peer, headers []*types.Header) types.Blocks {
	// Determine which headers carry a body.
	needBodies := false
	for _, hd := range headers {
		if hd.TxHash != types.EmptyTxsHash || hd.UncleHash != types.EmptyUncleHash || hd.WithdrawalsHash != nil {
			needBodies = true
			break
		}
	}
	var bodies []*eth.BlockBody
	if needBodies {
		hashes := make([]common.Hash, len(headers))
		for i, hd := range headers {
			hashes[i] = hd.Hash()
		}
		if fetched, err := h.fetchBodies(peer, hashes); err == nil && len(fetched) == len(headers) {
			bodies = fetched
		} else {
			log.Debug("RandomX backfill: body fetch incomplete, using headers only", "err", err)
		}
	}
	blocks := make(types.Blocks, 0, len(headers))
	for i, hd := range headers {
		block := types.NewBlockWithHeader(hd)
		if bodies != nil {
			txs, _ := bodies[i].Transactions.Items()
			uncles, _ := bodies[i].Uncles.Items()
			var withdrawals types.Withdrawals
			if bodies[i].Withdrawals != nil {
				withdrawals, _ = bodies[i].Withdrawals.Items()
			}
			block = block.WithBody(types.Body{Transactions: txs, Uncles: uncles, Withdrawals: withdrawals})
		}
		blocks = append(blocks, block)
	}
	return blocks
}

// fetchBodies performs a blocking request for the block bodies of the given hashes.
func (h *ethHandler) fetchBodies(peer *eth.Peer, hashes []common.Hash) ([]*eth.BlockBody, error) {
	resCh := make(chan *eth.Response, 1)
	req, err := peer.RequestBodies(hashes, resCh)
	if err != nil {
		return nil, err
	}
	defer req.Close()

	select {
	case res := <-resCh:
		bodies, ok := res.Res.(*eth.BlockBodiesResponse)
		res.Done <- nil
		if !ok {
			return nil, fmt.Errorf("unexpected body response type %T", res.Res)
		}
		resp := *bodies
		out := make([]*eth.BlockBody, len(resp))
		for i := range resp {
			out[i] = &resp[i]
		}
		return out, nil
	case <-time.After(10 * time.Second):
		return nil, errors.New("body request timed out")
	}
}

// findCommonAncestor binary-searches for the highest block number at which our
// canonical chain and the peer's agree, returning that number. Since both sides
// are canonical chains sharing the same genesis, "hashes match at height n" is
// monotone (true up to the fork point, false after), so a bisection over
// [0, min(head, target)] needs only O(log n) header round trips. Any fetch or
// lookup failure is treated conservatively as a mismatch; the worst case is
// falling back toward genesis (0), never past the true ancestor.
func (h *ethHandler) findCommonAncestor(peer *eth.Peer, target uint64) uint64 {
	hi := h.chain.CurrentBlock().Number.Uint64()
	if target < hi {
		hi = target
	}
	// Invariant: everything at or below lo matches (genesis is shared), everything
	// above hi mismatches or is unknown.
	lo := uint64(0)
	for lo < hi {
		mid := lo + (hi-lo+1)/2
		ours := h.chain.GetHeaderByNumber(mid)
		hdrs, err := h.fetchHeaders(peer, mid, 1)
		if err == nil && len(hdrs) == 1 && ours != nil && ours.Hash() == hdrs[0].Hash() {
			lo = mid
		} else {
			hi = mid - 1
		}
	}
	return lo
}

// fetchHeaders performs a blocking request for up to amount contiguous headers
// starting at block number from.
func (h *ethHandler) fetchHeaders(peer *eth.Peer, from uint64, amount int) ([]*types.Header, error) {
	resCh := make(chan *eth.Response, 1)
	req, err := peer.RequestHeadersByNumber(from, amount, 0, false, resCh)
	if err != nil {
		return nil, err
	}
	defer req.Close()

	select {
	case res := <-resCh:
		headers, ok := res.Res.(*eth.BlockHeadersRequest)
		res.Done <- nil
		if !ok {
			return nil, fmt.Errorf("unexpected header response type %T", res.Res)
		}
		return *headers, nil
	case <-time.After(10 * time.Second):
		return nil, errors.New("header request timed out")
	}
}

// handleTransactions marks all given transactions as known to the peer
// and performs basic validations.
func handleTransactions(peer *eth.Peer, list []*types.Transaction, directBroadcast bool) error {
	seen := make(map[common.Hash]struct{}, len(list))
	for _, tx := range list {
		if tx.Type() == types.BlobTxType {
			if directBroadcast {
				return errors.New("disallowed broadcast blob transaction")
			} else {
				// If we receive any blob transactions missing sidecars, or with
				// sidecars that don't correspond to the versioned hashes reported
				// in the header, disconnect from the sending peer.
				if tx.BlobTxSidecar() == nil {
					return errors.New("received sidecar-less blob transaction")
				}
				if err := tx.BlobTxSidecar().ValidateBlobCommitmentHashes(tx.BlobHashes()); err != nil {
					return err
				}
			}
		}

		// Check for duplicates.
		hash := tx.Hash()
		if _, exists := seen[hash]; exists {
			return fmt.Errorf("multiple copies of the same hash %v", hash)
		}
		seen[hash] = struct{}{}

		// Mark as known.
		peer.MarkTransaction(hash)
	}
	return nil
}
