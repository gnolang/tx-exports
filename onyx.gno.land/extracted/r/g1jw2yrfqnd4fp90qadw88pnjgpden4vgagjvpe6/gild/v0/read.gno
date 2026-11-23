package gild

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
)

// ---- JSON views for apps ----

// TaskJSON returns one task as JSON, or "null" if it does not exist.
func TaskJSON(id int64) string {
	if id < 1 {
		return "null"
	}
	v := tasks.Get(seqid.ID(id).Binary())
	if v == nil {
		return "null"
	}
	return taskJSON(v.(*Task))
}

// TasksJSON lists tasks newest first. filter is "open" or "all".
func TasksJSON(filter string, offset, limit int) string {
	switch filter {
	case "open":
		return pageJSON(&openTasks, offset, limit)
	case "all":
		return pageJSON(&tasks, offset, limit)
	}
	return `{"total":0,"items":[]}`
}

// PosterTasksJSON lists tasks posted by addr, newest first.
func PosterTasksJSON(addr address, offset, limit int) string {
	return pageJSON(sub(&byPoster, addr), offset, limit)
}

// DoerTasksJSON lists tasks taken by addr, newest first.
func DoerTasksJSON(addr address, offset, limit int) string {
	return pageJSON(sub(&byDoer, addr), offset, limit)
}

// StatsJSON returns board totals.
func StatsJSON() string {
	var b strings.Builder
	b.WriteString(`{"open":`)
	b.WriteString(strconv.Itoa(openTasks.Size()))
	b.WriteString(`,"tasks":`)
	b.WriteString(strconv.Itoa(tasks.Size()))
	b.WriteString(`,"locked":`)
	b.WriteString(strconv.FormatInt(lockedTotal, 10))
	b.WriteString(`,"paid":`)
	b.WriteString(strconv.FormatInt(paidTotal, 10))
	b.WriteString(`,"completed":`)
	b.WriteString(strconv.Itoa(book.Total()))
	b.WriteString(`,"builders":`)
	b.WriteString(strconv.Itoa(book.Size()))
	b.WriteString(`,"denom":"` + Denom + `"}`)
	return b.String()
}

// ProfileJSON returns the work record of addr.
func ProfileJSON(addr address) string {
	p := book.Profile(addr)
	var b strings.Builder
	b.WriteString(`{"address":`)
	b.WriteString(jsonStr(addr.String()))
	b.WriteString(`,"completed":`)
	b.WriteString(strconv.Itoa(p.Completed))
	b.WriteString(`,"earned":`)
	b.WriteString(strconv.FormatInt(p.Earned, 10))
	b.WriteString(`,"posted":`)
	b.WriteString(strconv.Itoa(p.Posted))
	b.WriteString(`,"spent":`)
	b.WriteString(strconv.FormatInt(p.Spent, 10))
	b.WriteString(`,"recent":[`)
	for i, r := range p.Recent() {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(`{"taskId":`)
		b.WriteString(jsonStr(r.TaskID))
		b.WriteString(`,"title":`)
		b.WriteString(jsonStr(r.Title))
		b.WriteString(`,"poster":`)
		b.WriteString(jsonStr(r.Poster.String()))
		b.WriteString(`,"doer":`)
		b.WriteString(jsonStr(r.Doer.String()))
		b.WriteString(`,"amount":`)
		b.WriteString(strconv.FormatInt(r.Amount, 10))
		b.WriteString(`,"at":`)
		b.WriteString(strconv.FormatInt(r.At.Unix(), 10))
		b.WriteByte('}')
	}
	b.WriteString("]}")
	return b.String()
}

func sub(tree *avl.Tree, addr address) *avl.Tree {
	if v := tree.Get(addr.String()); v != nil {
		return v.(*avl.Tree)
	}
	return avl.NewTree()
}

func clampPage(offset, limit int) (int, int) {
	if offset < 0 {
		offset = 0
	}
	if limit < 1 || limit > MaxPage {
		limit = MaxPage
	}
	return offset, limit
}

func pageJSON(tree *avl.Tree, offset, limit int) string {
	offset, limit = clampPage(offset, limit)
	var b strings.Builder
	b.WriteString(`{"total":`)
	b.WriteString(strconv.Itoa(tree.Size()))
	b.WriteString(`,"items":[`)
	first := true
	tree.ReverseIterateByOffset(offset, limit, func(_ string, v any) bool {
		if !first {
			b.WriteByte(',')
		}
		first = false
		b.WriteString(taskJSON(v.(*Task)))
		return false
	})
	b.WriteString("]}")
	return b.String()
}

func taskJSON(t *Task) string {
	var b strings.Builder
	b.WriteString(`{"id":`)
	b.WriteString(strconv.FormatInt(int64(t.ID), 10))
	b.WriteString(`,"title":`)
	b.WriteString(jsonStr(t.Title))
	b.WriteString(`,"details":`)
	b.WriteString(jsonStr(t.Details))
	b.WriteString(`,"done":`)
	b.WriteString(jsonStr(t.Done))
	b.WriteString(`,"category":`)
	b.WriteString(jsonStr(t.Category))
	b.WriteString(`,"poster":`)
	b.WriteString(jsonStr(t.Poster.String()))
	b.WriteString(`,"doer":`)
	b.WriteString(jsonStr(t.Doer.String()))
	b.WriteString(`,"reward":`)
	b.WriteString(strconv.FormatInt(t.Reward, 10))
	b.WriteString(`,"denom":"` + Denom + `","status":"`)
	b.WriteString(t.Status.String())
	b.WriteString(`","createdAt":`)
	b.WriteString(unix(t.CreatedAt))
	b.WriteString(`,"deadline":`)
	b.WriteString(unix(t.Deadline))
	b.WriteString(`,"takenAt":`)
	b.WriteString(unix(t.TakenAt))
	b.WriteString(`,"submittedAt":`)
	b.WriteString(unix(t.SubmittedAt))
	b.WriteString(`,"closedAt":`)
	b.WriteString(unix(t.ClosedAt))
	b.WriteString(`,"claimableAt":`)
	if t.Status == StatusInReview {
		b.WriteString(unix(t.SubmittedAt.Add(ReviewWindow)))
	} else {
		b.WriteString("0")
	}
	b.WriteString(`,"workUrl":`)
	b.WriteString(jsonStr(t.WorkURL))
	b.WriteString(`,"changesAsked":`)
	b.WriteString(strconv.FormatBool(t.ChangesAsked))
	b.WriteString(`,"changesNote":`)
	b.WriteString(jsonStr(t.ChangesNote))
	b.WriteString(`,"paidBy":`)
	b.WriteString(jsonStr(t.PaidBy))
	b.WriteByte('}')
	return b.String()
}

func unix(t time.Time) string {
	if t.IsZero() {
		return "0"
	}
	return strconv.FormatInt(t.Unix(), 10)
}

// jsonStr returns s as a JSON string literal. It also escapes <, > and & so
// the output is safe to place inside HTML.
func jsonStr(s string) string {
	const hex = "0123456789abcdef"
	var b strings.Builder
	b.WriteByte('"')
	for _, r := range s {
		switch {
		case r == '"':
			b.WriteString(`\"`)
		case r == '\\':
			b.WriteString(`\\`)
		case r == '\n':
			b.WriteString(`\n`)
		case r == '\t':
			b.WriteString(`\t`)
		case r < 0x20 || r == '<' || r == '>' || r == '&' || r == 0x2028 || r == 0x2029:
			b.WriteString(`\u`)
			b.WriteByte(hex[(r>>12)&0xf])
			b.WriteByte(hex[(r>>8)&0xf])
			b.WriteByte(hex[(r>>4)&0xf])
			b.WriteByte(hex[r&0xf])
		default:
			b.WriteRune(r)
		}
	}
	b.WriteByte('"')
	return b.String()
}

// ---- gnoweb pages ----

// Render serves "" (open tasks), "task/<id>" and "u/<address>".
func Render(path string) string {
	switch {
	case path == "":
		return renderHome()
	case strings.HasPrefix(path, "task/"):
		id, err := strconv.ParseInt(strings.TrimPrefix(path, "task/"), 10, 64)
		if err != nil || id < 1 {
			return "# Not found"
		}
		v := tasks.Get(seqid.ID(id).Binary())
		if v == nil {
			return "# Not found"
		}
		return renderTask(v.(*Task))
	case strings.HasPrefix(path, "u/"):
		addr := address(strings.TrimPrefix(path, "u/"))
		if !addr.IsValid() {
			return "# Not found"
		}
		return renderProfile(addr)
	}
	return "# Not found"
}

func renderHome() string {
	var b strings.Builder
	b.WriteString("# Gild\n\nPost work. Pay on proof.\n\n")
	b.WriteString("**" + strconv.Itoa(openTasks.Size()) + "** open · **" + gnot(lockedTotal) + "** locked · **" + gnot(paidTotal) + "** paid\n\n")
	b.WriteString("## Open tasks\n\n")
	if openTasks.Size() == 0 {
		b.WriteString("No open tasks yet.\n")
		return b.String()
	}
	openTasks.ReverseIterateByOffset(0, 20, func(_ string, v any) bool {
		t := v.(*Task)
		b.WriteString("- [" + mdText(t.Title) + "](" + webPath + ":task/" + idStr(t.ID) + ") · **" + gnot(t.Reward) + "** · " + t.Category + " · due " + t.Deadline.UTC().Format("Jan 2, 2006") + "\n")
		return false
	})
	return b.String()
}

func renderTask(t *Task) string {
	var b strings.Builder
	b.WriteString("# " + mdText(t.Title) + "\n\n")
	b.WriteString("**" + gnot(t.Reward) + "** · " + t.Status.String() + " · " + t.Category + "\n\n")
	b.WriteString("Posted by [" + t.Poster.String() + "](" + webPath + ":u/" + t.Poster.String() + ")")
	if t.Doer != "" {
		b.WriteString(" · taken by [" + t.Doer.String() + "](" + webPath + ":u/" + t.Doer.String() + ")")
	}
	b.WriteString("\n\nDeadline: " + t.Deadline.UTC().Format("Jan 2, 2006 15:04 MST") + "\n\n")
	if t.Details != "" {
		b.WriteString("## The task\n\n" + mdText(t.Details) + "\n\n")
	}
	if t.Done != "" {
		b.WriteString("## Done looks like\n\n" + mdText(t.Done) + "\n\n")
	}
	if t.WorkURL != "" {
		b.WriteString("## Work\n\n" + mdText(t.WorkURL) + "\n\n")
	}
	if t.Status == StatusInReview {
		b.WriteString("The doer can claim the reward after " + t.SubmittedAt.Add(ReviewWindow).UTC().Format("Jan 2, 2006 15:04 MST") + " if the poster does not answer.\n")
	}
	return b.String()
}

func renderProfile(addr address) string {
	p := book.Profile(addr)
	var b strings.Builder
	b.WriteString("# " + addr.String() + "\n\n")
	b.WriteString("**" + strconv.Itoa(p.Completed) + "** tasks done · **" + gnot(p.Earned) + "** earned · **" + strconv.Itoa(p.Posted) + "** paid out\n\n")
	recent := p.Recent()
	if len(recent) == 0 {
		b.WriteString("No finished work yet.\n")
		return b.String()
	}
	b.WriteString("## Recent work\n\n")
	for _, r := range recent {
		b.WriteString("- [" + mdText(r.Title) + "](" + webPath + ":task/" + r.TaskID + ") · " + gnot(r.Amount) + " · " + r.At.UTC().Format("Jan 2, 2006") + "\n")
	}
	return b.String()
}

// mdText escapes characters that would turn user text into markdown links,
// images, headings or HTML.
func mdText(s string) string {
	r := strings.NewReplacer(
		`\`, `\\`, "[", `\[`, "]", `\]`, "(", `\(`, ")", `\)`,
		"<", "&lt;", ">", "&gt;", "`", "\\`", "*", `\*`, "_", `\_`, "#", `\#`, "!", `\!`,
	)
	return r.Replace(s)
}

// gnot formats an amount in ugnot as GNOT, e.g. 1500000 -> "1.5 GNOT".
func gnot(u int64) string {
	whole := u / 1_000_000
	frac := u % 1_000_000
	s := strconv.FormatInt(whole, 10)
	if frac != 0 {
		f := strconv.FormatInt(frac+1_000_000, 10)[1:]
		s += "." + strings.TrimRight(f, "0")
	}
	return s + " GNOT"
}
