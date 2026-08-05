package gnochat

import (
	"chain"
	"strings"
	"time"
	"unicode/utf8"

	"gno.land/p/nt/seqid/v0"
)

// PostMessage stores one short public message on-chain.
func PostMessage(cur realm, channelID, content string) string {
	channel := mustGetChannel(channelID)
	caller := cur.Previous().Address()
	rawMember := channel.members.Get(caller.String())
	if rawMember == nil {
		panic("only channel members can post")
	}
	member := rawMember.(*Member)
	if member.muted {
		panic("member is muted")
	}

	content = strings.TrimSpace(content)
	assertValidMessage(content)
	id := channel.messageSequence.Next()
	message := &Message{
		id:        id,
		author:    caller,
		content:   content,
		createdAt: time.Now(),
	}
	channel.messages.Set(id.String(), message)

	chain.Emit(
		"MessagePosted",
		"channelID", channel.id.String(),
		"messageID", id.String(),
		"author", caller.String(),
	)
	return id.String()
}

func MessageCount(channelID string) int {
	return mustGetChannel(channelID).messages.Size()
}

func GetMessage(channelID, messageID string) (MessageView, bool) {
	channel := mustGetChannel(channelID)
	id, err := seqid.FromString(messageID)
	if err != nil || id == 0 {
		return MessageView{}, false
	}
	raw := channel.messages.Get(id.String())
	if raw == nil {
		return MessageView{}, false
	}
	return raw.(*Message).view(), true
}

// MessageAt returns browser-friendly scalar fields for one message at index.
func MessageAt(channelID string, index int) (
	id, author, content string,
	createdAt int64,
	found bool,
) {
	channel, channelFound := getChannel(channelID)
	if !channelFound || index < 0 || index >= channel.messages.Size() {
		return "", "", "", 0, false
	}

	_, raw := channel.messages.GetByIndex(index)
	message := raw.(*Message)
	return message.id.String(), message.author.String(), message.content,
		message.createdAt.Unix(), true
}

func assertValidMessage(content string) {
	if content == "" {
		panic("message cannot be empty")
	}
	if utf8.RuneCountInString(content) > MaxMessageLength {
		panic("message is too long")
	}
}

