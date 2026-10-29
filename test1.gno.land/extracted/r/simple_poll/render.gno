package poll

import (
	"strconv"
	"strings"

	"gno.land/p/avl"
	"gno.land/p/ufmt"
)

const pkgPath = "/r/simple_poll"

func Render(path string) string {
	if path == "" {
		return renderPolls()
	}
	parts := strings.Split(path, "/")
	if len(parts) == 1 {
		pid := parts[0]
		return renderPoll(pid)
	}

	return ""
}

func renderPolls() string {
	var b strings.Builder
	b.WriteString("## Polls:\n\n")
	polls.Iterate("", "", func(n *avl.Tree) bool {
		poll := n.Value().(*Poll)
		b.WriteString("- [" + poll.title + "]")
		b.WriteString(ufmt.Sprintf("(%s:%s)", pkgPath, poll.id.String()))
		b.WriteString("\n`total: " + strconv.Itoa(poll.VoteTotal()) + "`")
		b.WriteString("\n\n")

		return false
	})
	b.WriteString("---\n")
	b.WriteString("[[Create](" + pkgPath + "?help&__func=CreatePoll)]\n")

	return b.String()
}

func renderPoll(pid string) string {
	p, exists := polls.Get(pid)
	if !exists {
		return "# 404: Not found"
	}

	poll := p.(*Poll)

	var b strings.Builder
	b.WriteString("# " + poll.title)
	b.WriteString("\n\n")
	b.WriteString("- total: " + strconv.Itoa(poll.VoteTotal()) + "\n\n")
	b.WriteString(renderPollOptions(poll))
	b.WriteString("---\n")
	b.WriteString(ufmt.Sprintf("[[Add option](%s?help&__func=AddPollOption&pollID=%s)]\n", pkgPath, poll.id.String()))

	return b.String()
}

func renderPollOptions(poll *Poll) string {
	var b strings.Builder
	poll.options.Iterate("", "", func(n *avl.Tree) bool {
		id := n.Key()
		option := n.Value().(string)
		voteCnt := poll.voteCountByOptionID(id)
		b.WriteString("### " + id + ". " + option + "\n")
		b.WriteString("- votes:" + strconv.Itoa(int(voteCnt)) + "    ")
		b.WriteString(ufmt.Sprintf("- [[Vote](%s)]\n\n", getVoteURL(poll.id.String(), id)))

		return false
	})

	return b.String()
}

func getVoteURL(pollID string, optionID string) string {
	return ufmt.Sprintf("%s?help&__func=Vote&pollID=%s&optionID=%s", pkgPath, pollID, optionID)
}
