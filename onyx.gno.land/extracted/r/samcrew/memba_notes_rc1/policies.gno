package memba_notes_rc1

import (
	"gno.land/p/samcrew/avl"
	"strconv"
	"strings"
)

const (
	OpRead uint8 = iota
	OpWrite
	OpComment
)

// The realm parameter forces an explicit crossing: adapters run with their own
// realm identity. All mutators retain the busy guard throughout callbacks.
type Policy interface {
	Allows(cur realm, id [16]byte, who address, op uint8) bool
}

var policies = avl.NewTree()

func RegisterPolicy(cur realm, slug string, p Policy) string {
	enter(cur, false)
	defer leave()
	path := cur.Previous().PkgPath()
	if !strings.HasPrefix(path, "gno.land/r/") || len(path) > 200 || len(slug) < 1 || len(slug) > 32 || p == nil {
		panic("notes: realm policy required")
	}
	for _, c := range slug {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
			panic("notes: invalid policy slug")
		}
	}
	key := path + ":" + slug
	if _, ok := policies.Get(key); ok {
		panic("notes: policy already registered")
	}
	policies.Set(key, p)
	return key
}
func SetPolicy(cur realm, id [16]byte, baseRevision uint64, op uint8, key string, opID [16]byte) {
	who := enter(cur, false)
	defer leave()
	mutateSetPolicy(cur, who, id, baseRevision, op, key, opID)
}
func mutateSetPolicy(cur realm, who address, id [16]byte, baseRevision uint64, op uint8, key string, opID [16]byte) {
	n := live(id)
	owner(n, who)
	expected(n, baseRevision)
	if op > OpComment {
		panic("notes: unknown policy operation")
	}
	if key != "" {
		if _, ok := policies.Get(key); !ok {
			panic("notes: policy missing")
		}
	}
	operation(n, opID)
	n.Policies[op] = key
	bumpHistory(n, who, opID, "policy", `,"policy_op":`+strconv.Itoa(int(op))+`,"policy_key":`+q(key))
}
func policyAllows(cur realm, n *note, who address, op uint8) bool {
	key := n.Policies[op]
	if key == "" {
		return false
	}
	p, ok := policies.Get(key)
	if !ok {
		panic("notes: missing stored policy")
	}
	return p.(Policy).Allows(cross(cur), n.ID, who, op)
}
func PoliciesJSON(idHex string) string {
	n := find(readID(idHex))
	return `{"read":` + q(n.Policies[0]) + `,"write":` + q(n.Policies[1]) + `,"comment":` + q(n.Policies[2]) + `}`
}

// A holder may grant a read-policy-approved recipient the current epoch. Every
// existing entry must remain byte-identical: a grantee cannot corrupt someone
// else's wrap, change writers, remove access or rotate the owner into new keys.
func GrantAccess(cur realm, id [16]byte, baseRevision uint64, expectedEpoch uint32, manifest []byte, opID [16]byte) {
	who := enter(cur, false)
	defer leave()
	n := live(id)
	expected(n, baseRevision)
	privateWritable(n)
	if n.Mode != ModeShared || expectedEpoch != n.Epoch || !contains(n.Readers, who) {
		panic("notes: current shared reader required")
	}
	list := parseManifest(manifest, n.Epoch, manifestOwner(n), n.Mode)
	old := getEpoch(id, n.Epoch).Manifest
	for i := 0; i < int(old[1]); i++ {
		entry := old[2+i*ManifestEntryBytes : 2+(i+1)*ManifestEntryBytes]
		found := false
		for j := 0; j < int(manifest[1]); j++ {
			next := manifest[2+j*ManifestEntryBytes : 2+(j+1)*ManifestEntryBytes]
			if string(entry) == string(next) {
				found = true
				break
			}
		}
		if !found {
			panic("notes: existing wrap immutable for reader")
		}
	}
	added := false
	for _, r := range list {
		if !contains(n.Readers, r.Who) {
			govGrant := n.GovWriters && n.Owner == govAddress && govMember(who) && govMember(r.Who)
			if r.Writer || who != n.Owner && !govGrant && !policyAllows(cur, n, r.Who, OpRead) {
				panic("notes: read policy denied")
			}
			added = true
		}
	}
	if !added {
		panic("notes: no new reader")
	}
	operation(n, opID)
	unindex(n)
	setRecipients(n, list)
	index(n)
	getEpoch(id, n.Epoch).Manifest = copied(manifest)
	acknowledgeRequests(n, who, opID)
	bump(n, who, opID, "read-grant")
}
