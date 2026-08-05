package gnochat

import (
	"chain"
	"strings"
	"time"
	"unicode/utf8"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
)

var (
	channelSequence seqid.ID
	channels        = avl.NewTree() // seqid string -> *Channel
)

// CreateChannel creates a public channel and makes the caller its owner.
func CreateChannel(cur realm, name, description string) string {
	name = strings.TrimSpace(name)
	description = strings.TrimSpace(description)
	assertValidChannelName(name)
	assertValidChannelDescription(description)

	owner := cur.Previous().Address()
	id := channelSequence.Next()
	channel := &Channel{
		id:          id,
		name:        name,
		description: description,
		owner:       owner,
		createdAt:   time.Now(),
		members:     avl.NewTree(),
		messages:    avl.NewTree(),
	}
	channel.members.Set(owner.String(), &Member{
		addr:     owner,
		role:     RoleOwner,
		joinedAt: time.Now(),
	})
	channels.Set(id.String(), channel)

	chain.Emit(
		"ChannelCreated",
		"channelID", id.String(),
		"owner", owner.String(),
		"name", name,
	)
	return id.String()
}

// JoinChannel adds the caller to a public channel as a member.
func JoinChannel(cur realm, channelID string) {
	channel := mustGetChannel(channelID)
	caller := cur.Previous().Address()
	if channel.members.Has(caller.String()) {
		panic("already a channel member")
	}

	channel.members.Set(caller.String(), &Member{
		addr:     caller,
		role:     RoleMember,
		joinedAt: time.Now(),
	})
	chain.Emit(
		"ChannelJoined",
		"channelID", channel.id.String(),
		"member", caller.String(),
	)
}

// SetMemberRole promotes or demotes a member. Only the channel owner may do so.
func SetMemberRole(cur realm, channelID string, member address, role string) {
	channel := mustGetChannel(channelID)
	caller := cur.Previous().Address()
	assertOwner(channel, caller)
	assertValidManagedRole(role)
	if member == channel.owner {
		panic("the owner role cannot be changed")
	}

	target := mustGetMember(channel, member)
	target.role = role
	chain.Emit(
		"MemberRoleChanged",
		"channelID", channel.id.String(),
		"member", member.String(),
		"role", role,
		"caller", caller.String(),
	)
}

// MuteMember changes whether a member may post. Owners and admins may mute
// regular members; only the owner may mute an admin.
func MuteMember(cur realm, channelID string, member address, muted bool) {
	channel := mustGetChannel(channelID)
	caller := cur.Previous().Address()
	actor := mustGetMember(channel, caller)
	if actor.role != RoleOwner && actor.role != RoleAdmin {
		panic("only owners and admins can mute members")
	}
	if member == channel.owner {
		panic("the channel owner cannot be muted")
	}
	if member == caller {
		panic("members cannot mute themselves")
	}

	target := mustGetMember(channel, member)
	if target.role == RoleAdmin && actor.role != RoleOwner {
		panic("only the owner can mute an admin")
	}
	target.muted = muted

	chain.Emit(
		"MemberMuteChanged",
		"channelID", channel.id.String(),
		"member", member.String(),
		"muted", boolString(muted),
		"caller", caller.String(),
	)
}

func ChannelCount() int {
	return channels.Size()
}

func GetChannel(channelID string) (ChannelView, bool) {
	channel, found := getChannel(channelID)
	if !found {
		return ChannelView{}, false
	}
	return channel.view(), true
}

// ChannelAt returns browser-friendly scalar fields for the channel at index.
// Keeping this query separate from GetChannel avoids making clients decode Gno
// structs such as address and time.Time over JSON-RPC.
func ChannelAt(index int) (
	id, name, description, owner string,
	createdAt int64,
	memberCount, messageCount int,
	found bool,
) {
	if index < 0 || index >= channels.Size() {
		return "", "", "", "", 0, 0, 0, false
	}

	_, raw := channels.GetByIndex(index)
	channel := raw.(*Channel)
	return channel.id.String(), channel.name, channel.description,
		channel.owner.String(), channel.createdAt.Unix(),
		channel.members.Size(), channel.messages.Size(), true
}

func IsMember(channelID string, member address) bool {
	channel := mustGetChannel(channelID)
	return channel.members.Has(member.String())
}

func GetMemberRole(channelID string, member address) (string, bool) {
	channel := mustGetChannel(channelID)
	raw := channel.members.Get(member.String())
	if raw == nil {
		return "", false
	}
	return raw.(*Member).role, true
}

func IsMuted(channelID string, member address) bool {
	channel := mustGetChannel(channelID)
	return mustGetMember(channel, member).muted
}

func getChannel(channelID string) (*Channel, bool) {
	id, err := seqid.FromString(channelID)
	if err != nil || id == 0 {
		return nil, false
	}
	raw := channels.Get(id.String())
	if raw == nil {
		return nil, false
	}
	return raw.(*Channel), true
}

func mustGetChannel(channelID string) *Channel {
	channel, found := getChannel(channelID)
	if !found {
		panic("channel not found")
	}
	return channel
}

func mustGetMember(channel *Channel, member address) *Member {
	raw := channel.members.Get(member.String())
	if raw == nil {
		panic("channel member not found")
	}
	return raw.(*Member)
}

func assertOwner(channel *Channel, caller address) {
	if caller != channel.owner {
		panic("only the channel owner may perform this action")
	}
}

func assertValidManagedRole(role string) {
	if role != RoleAdmin && role != RoleMember {
		panic("role must be admin or member")
	}
}

func assertValidChannelName(name string) {
	length := utf8.RuneCountInString(name)
	if length < 3 {
		panic("channel name must contain at least 3 characters")
	}
	if length > MaxChannelNameLength {
		panic("channel name is too long")
	}
}

func assertValidChannelDescription(description string) {
	if utf8.RuneCountInString(description) > MaxChannelDescriptionLength {
		panic("channel description is too long")
	}
}

func boolString(value bool) string {
	if value {
		return "true"
	}
	return "false"
}

