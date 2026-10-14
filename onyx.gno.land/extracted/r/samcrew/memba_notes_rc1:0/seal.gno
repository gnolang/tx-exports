package memba_notes_rc1

import (
	"crypto/sha256"
	"encoding/hex"
	"strconv"
)

// Decorative fingerprint from public ciphertext only. It is not a historical
// inclusion proof or proof of knowledge of a plaintext/key.
func seal(body []byte) string {
	hash := sha256.Sum256(body)
	glyphs := []rune("◇◆○●□■△▲✦")
	out := "```\n"
	for i := 0; i < 81; i++ {
		out += string(glyphs[int(hash[i%32]+byte(i/32))%len(glyphs)])
		if i%9 == 8 {
			out += "\n"
		}
	}
	return out + "```\n"
}
func SealJSON(idHex string) string {
	n := find(readID(idHex))
	hash := sha256.Sum256(n.Body)
	return `{"id":` + q(idText(n.ID)) + `,"state_revision":` + u(n.Revision) + `,"body_revision":` + u(n.BodyRevision) + `,"epoch":` + u(uint64(n.Epoch)) + `,"ciphertext_sha256":` + q(hex.EncodeToString(hash[:])) + `,"encrypted":` + strconv.FormatBool(encrypted(n.Mode) && !n.Deleted) + `,"deleted":` + strconv.FormatBool(n.Deleted) + `,"height":` + q(strconv.FormatInt(n.Last.Height, 10)) + `,"historical_proof":false}`
}
