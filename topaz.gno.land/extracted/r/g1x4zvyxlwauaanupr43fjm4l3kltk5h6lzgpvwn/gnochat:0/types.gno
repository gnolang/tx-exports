package gnochat

import (
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
)

const (
	RoleOwner  = "owner"
	RoleAdmin  = "admin"
	RoleMember = "member"
)

const (
	MaxChannelNameLength        = 50
	MaxChannelDescriptionLength = 280
	MaxMessageLength            = 500
)

// Channel is the persisted state for one public chat channel.
// Members and messages use AVL trees so lookups stay efficient as they grow.
type Channel struct {
	id              seqid.ID
	name            string
	description     string
	owner           address
	createdAt       time.Time
	members         *avl.Tree // address string -> *Member
	messages        *avl.Tree // seqid string -> *Message
	messageSequence seqid.ID
}

type Member struct {
	addr     address
	role     string
	muted    bool
	joinedAt time.Time
}

type Message struct {
	id        seqid.ID
	author    address
	content   string
	createdAt time.Time
}

// ChannelView is a read-only copy returned to clients.
type ChannelView struct {
	ID           string
	Name         string
	Description  string
	Owner        address
	CreatedAt    time.Time
	MemberCount  int
	MessageCount int
}

// MessageView is a read-only copy returned to clients.
type MessageView struct {
	ID        string
	Author    address
	Content   string
	CreatedAt time.Time
}

func (c *Channel) view() ChannelView {
	return ChannelView{
		ID:           c.id.String(),
		Name:         c.name,
		Description:  c.description,
		Owner:        c.owner,
		CreatedAt:    c.createdAt,
		MemberCount:  c.members.Size(),
		MessageCount: c.messages.Size(),
	}
}

func (m *Message) view() MessageView {
	return MessageView{
		ID:        m.id.String(),
		Author:    m.author,
		Content:   m.content,
		CreatedAt: m.createdAt,
	}
}

