package memba_notes_v1

import (
	"bytes"
	"chain/runtime"
	"crypto/bech32"
	"crypto/sha256"
	"encoding/binary"
	keys "gno.land/r/samcrew/enckeys_v1"
	"strconv"
)

const ManifestEntryBytes = 1299
const MaxManifestBytes = 2 + MaxReaders*ManifestEntryBytes
const MaxCipherCommentBytes = 5687

type recipient struct {
	Who        address
	Writer     bool
	Generation uint64
}

func encrypted(mode uint8) bool { return mode <= ModeLink }
func contains(addrs []address, who address) bool {
	for _, a := range addrs {
		if a == who {
			return true
		}
	}
	return false
}
func parseManifest(data []byte, epoch uint32, owner address, mode uint8) []recipient {
	return parseManifestFor(data, epoch, owner, mode, "")
}

// A self refresh checks the new caller identity while preserving every other
// already-stored envelope, including revoked or superseded identities.
func parseManifestFor(data []byte, epoch uint32, owner address, mode uint8, currentOnly address) []recipient {
	if len(data) < 2 || len(data) > MaxManifestBytes || data[0] != 1 || data[1] < 1 || data[1] > MaxReaders || len(data) != 2+int(data[1])*ManifestEntryBytes {
		panic("notes: manifest header/length")
	}
	result := []recipient{}
	previous := []byte(nil)
	hasOwner := false
	hasWriter := false
	for i := 0; i < int(data[1]); i++ {
		off := 2 + i*ManifestEntryBytes
		raw := data[off : off+20]
		if i > 0 && bytes.Compare(raw, previous) <= 0 || data[off+20] > 1 {
			panic("notes: manifest order/role")
		}
		previous = raw
		encoded, err := bech32.EncodeFromBase256("g", raw)
		if err != nil {
			panic("notes: recipient address")
		}
		who := address(encoded)
		generation := binary.BigEndian.Uint64(data[off+21 : off+29])
		if generation == 0 {
			panic("notes: zero identity generation")
		}
		wr := off + 61
		if data[wr] != 1 || data[wr+1] != 1 || binary.BigEndian.Uint32(data[wr+2:wr+6]) != epoch {
			panic("notes: wrap suite/epoch")
		}
		if binary.BigEndian.Uint64(data[wr+6:wr+14]) != generation || !bytes.Equal(data[off+29:off+61], data[wr+14:wr+46]) {
			panic("notes: wrap identity mismatch")
		}
		if currentOnly == "" || currentOnly == who {
			pk, gen, active := keys.GetKey(who, keys.SuiteXWingV1)
			if !active || gen != generation {
				panic("notes: recipient key inactive/stale")
			}
			hash := sha256.Sum256(pk)
			if !bytes.Equal(hash[:], data[off+29:off+61]) {
				panic("notes: recipient public key hash")
			}
		}
		isWriter := data[off+20] == 1
		if isWriter {
			hasWriter = true
		}
		if who == owner {
			if !isWriter {
				panic("notes: owner must write")
			}
			hasOwner = true
		}
		if mode == ModeLink && !isWriter {
			panic("notes: link wraps are for writers")
		}
		result = append(result, recipient{who, isWriter, generation})
	}
	if owner != "" && (!hasOwner || !hasWriter) || mode == ModePrivate && (len(result) != 1 || owner == "") {
		panic("notes: missing owner/private readers")
	}
	return result
}
func validateCipher(blob []byte, epoch uint32, field uint8, revision uint64, cap int) {
	if len(blob) < 59 || len(blob) > cap || blob[0] != 1 || blob[1] != 1 || binary.BigEndian.Uint32(blob[2:6]) != epoch || blob[6] != field || binary.BigEndian.Uint64(blob[7:15]) != revision {
		panic("notes: invalid cipher envelope")
	}
}
func validateCommitment(kc []byte) {
	if len(kc) != 32 || bytes.Equal(kc, make([]byte, 32)) {
		panic("notes: invalid epoch commitment")
	}
}
func appendText(b []byte, s string) []byte {
	size := make([]byte, 4)
	binary.BigEndian.PutUint32(size, uint32(len(s)))
	b = append(b, size...)
	return append(b, []byte(s)...)
}
func epochCommitment(id [16]byte, epoch uint32, key []byte) []byte {
	b := appendText(nil, "memba-notes/v1/epoch-commitment")
	b = appendText(b, runtime.ChainID())
	b = appendText(b, RealmPath)
	b = append(b, id[:]...)
	ep := make([]byte, 4)
	binary.BigEndian.PutUint32(ep, epoch)
	b = append(b, ep...)
	b = append(b, key...)
	h := sha256.Sum256(b)
	return h[:]
}

func manifestAddress(raw []byte) address {
	s, err := bech32.EncodeFromBase256("g", raw)
	if err != nil {
		panic("notes: manifest address")
	}
	return address(s)
}

func canonicalRecipient(who address) address { return keys.CanonicalAddress(who) }
func wrapJSON(entry []byte, epoch uint32, who address) string {
	return `{"address":` + q(string(who)) + `,"epoch":` + u(uint64(epoch)) + `,"writer":` + strconv.FormatBool(entry[20] == 1) + `,"generation":` + u(binary.BigEndian.Uint64(entry[21:29])) + `,"public_key_hash":` + blob(entry[29:61]) + `,"wrap":` + blob(entry[61:]) + `}`
}
