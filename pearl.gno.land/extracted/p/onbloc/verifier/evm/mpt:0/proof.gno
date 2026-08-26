package mpt

import (
	"bytes"
	"encoding/hex"

	"gno.land/p/nt/ufmt/v0"
)

// missingNodeError reports which proof node index/hash verifyProof needed
// but didn't find, mirroring VerifyProof's "proof node %d (hash %064x)
// missing" message. It satisfies errors.Is(err, ErrMissingNode) via Is, since
// ufmt.Errorf has no %w wrapping to attach the sentinel directly.
type missingNodeError struct {
	index int
	hash  [32]byte
}

func (e *missingNodeError) Error() string {
	return ufmt.Sprintf("mpt: proof node %d (hash %s) missing", e.index, hex.EncodeToString(e.hash[:]))
}

func (e *missingNodeError) Is(target error) bool {
	return target == ErrMissingNode
}

// verifyProof mirrors VerifyProof (proofDb pre-indexed by hash, matching how
// go-ethereum's caller populates it via Prove).
// Reference:
// https://github.com/ethereum/go-ethereum/blob/v1.10.26/trie/proof.go#L111-L135
func verifyProof(rootHash [32]byte, key []byte, proofDb map[[32]byte][]byte) ([]byte, error) {
	key = keybytesToHex(key)
	wantHash := rootHash

	for i := 0; ; i++ {
		buf, ok := proofDb[wantHash]
		if !ok {
			return nil, &missingNodeError{index: i, hash: wantHash}
		}

		n, err := decodeNode(buf)
		if err != nil {
			return nil, err
		}

		keyrest, cld := get(n, key, true)

		switch c := cld.(type) {
		case nil:
			return nil, nil
		case hashNode:
			key = keyrest
			copy(wantHash[:], c)
		case valueNode:
			return c, nil
		}
	}
}

// get mirrors get.
// Reference:
// https://github.com/ethereum/go-ethereum/blob/v1.10.26/trie/proof.go#L580-L608
func get(tn node, key []byte, skipResolved bool) ([]byte, node) {
	for {
		switch n := tn.(type) {
		case *shortNode:
			if len(key) < len(n.Key) || !bytes.Equal(n.Key, key[:len(n.Key)]) {
				return nil, nil
			}

			tn = n.Val
			key = key[len(n.Key):]

			if !skipResolved {
				return key, tn
			}

		case *fullNode:
			tn = n.Children[key[0]]
			key = key[1:]

			if !skipResolved {
				return key, tn
			}

		case hashNode:
			return key, n

		case nil:
			return key, nil

		case valueNode:
			return nil, n
		}
	}
}
