package gnochat

import (
	"strconv"
	"strings"

	"gno.land/p/moul/md"
	"gno.land/p/nt/markdown/sanitize/v0"
)

// Render exposes a simple read-only UI through gnoweb.
// All persisted user input is sanitized before being returned as Markdown.
func Render(path string) string {
	path = strings.Trim(path, "/")
	if path == "" {
		return renderChannelList()
	}
	if strings.HasPrefix(path, "c/") {
		return renderChannel(strings.TrimPrefix(path, "c/"))
	}
	return md.H1("GnoChat") + "Page not found.\n"
}

func renderChannelList() string {
	out := md.H1("GnoChat")
	out += "Public, wallet-owned channels on Gno.land.\n\n"
	if channels.Size() == 0 {
		return out + "No channels yet. Call `CreateChannel` to create one.\n"
	}

	channels.Iterate("", "", func(_ string, raw any) bool {
		channel := raw.(*Channel)
		out += md.H3(md.Link(channel.name, "c/"+channel.id.String()))
		if channel.description != "" {
			out += sanitize.Block(channel.description) + "\n\n"
		}
		out += strconv.Itoa(channel.members.Size()) + " members · "
		out += strconv.Itoa(channel.messages.Size()) + " messages\n\n"
		return false
	})
	return out
}

func renderChannel(channelID string) string {
	channel, found := getChannel(channelID)
	if !found {
		return md.H1("GnoChat") + "Channel not found.\n"
	}

	out := md.H1(sanitize.InlineText(channel.name))
	if channel.description != "" {
		out += sanitize.Block(channel.description) + "\n\n"
	}
	out += "Owner: " + md.InlineCode(channel.owner.String()) + "\n\n"
	out += strconv.Itoa(channel.members.Size()) + " members · "
	out += strconv.Itoa(channel.messages.Size()) + " messages\n\n"
	out += md.HorizontalRule()

	if channel.messages.Size() == 0 {
		return out + "No messages yet.\n"
	}

	channel.messages.Iterate("", "", func(_ string, raw any) bool {
		message := raw.(*Message)
		out += md.H4("Message " + sanitize.InlineText(message.id.String()))
		out += sanitize.Block(message.content) + "\n\n"
		out += "— " + md.InlineCode(message.author.String()) + ", "
		out += sanitize.InlineText(message.createdAt.Format("02 Jan 2006, 15:04")) + "\n\n"
		return false
	})
	return out
}

