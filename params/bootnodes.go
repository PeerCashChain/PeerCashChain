// Copyright 2015 The go-ethereum Authors
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

package params

import "github.com/ethereum/go-ethereum/common"

// MainnetBootnodes are the enode URLs of the P2P bootstrap nodes running on
// the PeerCash testnet (chain ID 563321).
var MainnetBootnodes = []string{
	"enode://39c0e17ff5f0020a70f4f4a9a69c09d9f962e659d9840abb44bfafd335ae934d94b7b2832840da192eae4637ed62fa9e84ac08cd915ece86907241d5bf8cc769@167.71.186.249:30303",
}

// MainnetStaticNodes are the enode URLs of known-good PeerCash nodes that
// every node should always try to stay connected to. PeerCash has no
// downloader-driven sync (see eth/catchup.go): a node only ever learns of
// blocks it missed via a live peer connection, so on a small network
// dominated by unrelated public devp2p scanner traffic, discovery alone
// isn't reliable enough to keep known nodes meshed. Unlike bootnodes (used
// once to seed discovery), static nodes are dialed and redialed for the
// lifetime of the process.
var MainnetStaticNodes = []string{
	"enode://39c0e17ff5f0020a70f4f4a9a69c09d9f962e659d9840abb44bfafd335ae934d94b7b2832840da192eae4637ed62fa9e84ac08cd915ece86907241d5bf8cc769@167.71.186.249:30303",
}

// HoodiBootnodes are the enode URLs of the P2P bootstrap nodes running on the
// Hoodi test network.
var HoodiBootnodes = []string{
}

// HoleskyBootnodes are the enode URLs of the P2P bootstrap nodes running on the
// Holesky test network.
var HoleskyBootnodes = []string{
}

// SepoliaBootnodes are the enode URLs of the P2P bootstrap nodes running on the
// Sepolia test network.
var SepoliaBootnodes = []string{
}

var V5Bootnodes = []string{
}

const dnsPrefix = "enrtree://AKA3AM6LPBYEUDMVNU3BSVQJ5AD45Y7YPOHJLEF6W26QOE4VTUDPE@"

// KnownDNSNetwork returns the address of a public DNS-based node list for the given
// genesis hash and protocol. See https://github.com/ethereum/discv4-dns-lists for more
// information.
func KnownDNSNetwork(genesis common.Hash, protocol string) string {
	var net string
	switch genesis {
	case MainnetGenesisHash:
		net = "mainnet"
	case SepoliaGenesisHash:
		net = "sepolia"
	case HoleskyGenesisHash:
		net = "holesky"
	case HoodiGenesisHash:
		net = "hoodi"
	default:
		return ""
	}
	return dnsPrefix + protocol + "." + net + ".ethdisco.net"
}
