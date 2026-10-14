// Package memba_notes_rc1 stores versioned Markdown notes and their receipts.
// Publication is immutable; deployment is gated on the complete contract audit.
package memba_notes_rc1

import "gno.land/p/samcrew/avl"

const RealmPath = "gno.land/r/samcrew/memba_notes_rc1"
const ReserveAddress address = "g1jw76lxvzjafw2kyjhdnzwggcftyhnlfjaer2u0"
const (
	ModePrivate uint8 = iota
	ModeShared
	ModeLink
	ModePublic
	ModePublicOpen
)
const (
	MaxBodyBytes        = 131072
	MaxCipherBodyBytes  = 135223
	MaxTitleBytes       = 160
	MaxCipherTitleBytes = 231
	MaxReaders          = 32
	MaxPage             = 50
)

type receipt struct {
	Operation [16]byte
	Actor     address
	Height    int64
}
type note struct {
	ID                                    [16]byte
	Owner, PendingOwner                   address
	OwnerGeneration                       uint64
	Writers                               []address
	Readers                               []address
	OwnerIsRealm                          bool
	Policies                              [3]string
	RequestCount                          uint16
	GovWriters                            bool
	LastExecutor                          address
	Mode                                  uint8
	Revision, TitleRevision, BodyRevision uint64
	Epoch                                 uint32
	Title, Body, Commitment               []byte
	BodyBytes                             int
	CreatedHeight                         int64
	Sequence                              uint64
	CommentSequence                       uint64
	Last                                  receipt
	Deleted, Listed                       bool
	ModeratorHidden                       bool
	History                               *historyInfo // public notes only
}

var notes = avl.NewTree()
var ownerIndex = avl.NewTree()
var publicIndex = avl.NewTree()
var sharedIndex = avl.NewTree()
var sequence uint64
var busy bool
var admin, pendingAdmin address
var treasury = ReserveAddress
var createFee int64 = 100000
var paused bool
