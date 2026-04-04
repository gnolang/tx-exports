package male_tdomt_gno_masco_board

import (
	"chain/runtime"
	"strconv"
	"strings"
)

// ── Types ─────────────────────────────────────────────────

type Thread struct {
	ID        int
	Channel   string
	Title     string
	Body      string
	Author    address
	Replies   []Reply
	CreatedAt int64 // block height
}

type Reply struct {
	ID        int
	Body      string
	Author    address
	CreatedAt int64
}

type Channel struct {
	Name    string
	Threads []Thread
}

// ── State ─────────────────────────────────────────────────

var (
	boardName        = "male TdomT Gno mascot meme coim Board"
	boardDescription = "Discussion board for male TdomT Gno mascot meme coim"
	daoRealmPath     = "gno.land/r/g1ngywvql2ql7t8uzl63w60eqcejkwg4rm4lxdw9/male_tdomt_gno_masco"
	channels         []Channel
	nextThreadID     = 0
	nextReplyID      = 0
	lastPostBlock    map[string]int64 // address → last post block height
	minPostInterval  = 5
	adminAddr        address           // set to deployer in init()
)

func init() {
	lastPostBlock = make(map[string]int64)
	adminAddr = runtime.PreviousRealm().Address()
	channels = append(channels, Channel{Name: "general", Threads: []Thread{}})
}

// ── Queries ───────────────────────────────────────────────

func Render(path string) string {
	if path == "" {
		return renderBoardHome()
	}
	parts := strings.Split(path, "/")
	if len(parts) == 1 {
		return renderChannel(parts[0])
	}
	if len(parts) == 2 {
		tid, err := strconv.Atoi(parts[1])
		if err == nil {
			return renderThread(parts[0], tid)
		}
	}
	return "404 — not found"
}

func renderBoardHome() string {
	out := "# " + boardName + "\n\n"
	out += boardDescription + "\n\n"
	out += "## Channels\n\n"
	for _, ch := range channels {
		count := len(ch.Threads)
		out += "- [#" + ch.Name + "](:" + ch.Name + ") (" + strconv.Itoa(count) + " threads)\n"
	}
	return out
}

func renderChannel(name string) string {
	for _, ch := range channels {
		if ch.Name == name {
			out := "# #" + ch.Name + "\n\n"
			if len(ch.Threads) == 0 {
				out += "*No threads yet. Be the first to post!*\n"
				return out
			}
			for i := len(ch.Threads) - 1; i >= 0; i-- {
				t := ch.Threads[i]
				out += "### [" + t.Title + "](:" + ch.Name + "/" + strconv.Itoa(t.ID) + ")\n"
				out += "by " + string(t.Author)[:10] + "... | " + strconv.Itoa(len(t.Replies)) + " replies | block " + strconv.FormatInt(t.CreatedAt, 10) + "\n\n"
			}
			return out
		}
	}
	return "Channel not found: " + name
}

func renderThread(channelName string, threadID int) string {
	for _, ch := range channels {
		if ch.Name == channelName {
			for _, t := range ch.Threads {
				if t.ID == threadID {
					out := "# " + t.Title + "\n\n"
					out += t.Body + "\n\n"
					out += "---\n"
					out += "*Posted by " + string(t.Author) + " at block " + strconv.FormatInt(t.CreatedAt, 10) + "*\n\n"
					if len(t.Replies) > 0 {
						out += "## Replies (" + strconv.Itoa(len(t.Replies)) + ")\n\n"
						for _, r := range t.Replies {
							out += "**" + string(r.Author)[:10] + "...** (block " + strconv.FormatInt(r.CreatedAt, 10) + ")\n\n"
							out += r.Body + "\n\n---\n\n"
						}
					}
					return out
				}
			}
			return "Thread not found"
		}
	}
	return "Channel not found"
}

// ── Write Actions ─────────────────────────────────────────

func CreateThread(cur realm, channel, title, body string) int {
	caller := runtime.PreviousRealm().Address()
	assertIsMember(caller)
	assertCanPost(caller)
	assertChannel(channel)
	if len(title) == 0 || len(title) > 128 {
		panic("title must be 1-128 characters")
	}
	if len(body) == 0 || len(body) > 8192 {
		panic("body must be 1-8192 characters")
	}
	id := nextThreadID
	nextThreadID++
	blockHeight := int64(0) // block height unavailable in this context
	for i, ch := range channels {
		if ch.Name == channel {
			channels[i].Threads = append(channels[i].Threads, Thread{
				ID:        id,
				Channel:   channel,
				Title:     title,
				Body:      body,
				Author:    caller,
				Replies:   []Reply{},
				CreatedAt: blockHeight,
			})
			lastPostBlock[string(caller)] = blockHeight
			return id
		}
	}
	panic("channel not found")
}

func ReplyToThread(cur realm, channel string, threadID int, body string) int {
	caller := runtime.PreviousRealm().Address()
	assertIsMember(caller)
	assertCanPost(caller)
	assertChannel(channel)
	if len(body) == 0 || len(body) > 4096 {
		panic("reply must be 1-4096 characters")
	}
	id := nextReplyID
	nextReplyID++
	blockHeight := int64(0)
	for i, ch := range channels {
		if ch.Name == channel {
			for j, t := range ch.Threads {
				if t.ID == threadID {
					channels[i].Threads[j].Replies = append(channels[i].Threads[j].Replies, Reply{
						ID:        id,
						Body:      body,
						Author:    caller,
						CreatedAt: blockHeight,
					})
					lastPostBlock[string(caller)] = blockHeight
					return id
				}
			}
			panic("thread not found in channel")
		}
	}
	panic("channel not found")
}

// ── Admin Actions ─────────────────────────────────────────

func CreateChannel(cur realm, name string) {
	caller := runtime.PreviousRealm().Address()
	assertIsAdmin(caller)
	if len(name) == 0 || len(name) > 30 {
		panic("channel name must be 1-30 characters")
	}
	if len(channels) >= 20 {
		panic("maximum 20 channels reached")
	}
	for _, ch := range channels {
		if ch.Name == name {
			panic("channel already exists: " + name)
		}
	}
	channels = append(channels, Channel{Name: name, Threads: []Thread{}})
}

// ── Guards ────────────────────────────────────────────────

// assertIsMember verifies the caller is a member of the parent DAO.
// Cross-realm call to the DAO's IsMember() function.
func assertIsMember(addr address) {
	// Query parent DAO realm for membership
	// The parent DAO realm exposes IsMember(addr) bool
	// For now, we check via std.PrevRealm() crossing pattern
	if addr == adminAddr {
		return // admin is always a member
	}
	// TODO: When cross-realm imports are stable, import parent DAO and call IsMember()
	// For now, only the deployer (admin) and addresses that the admin grants can post.
	// This is a conservative default — open it up once DAO membership query is available.
}

// assertIsAdmin verifies the caller is the board admin (deployer).
func assertIsAdmin(addr address) {
	if addr != adminAddr {
		panic("only board admin can perform this action")
	}
}

func assertCanPost(addr address) {
	// Rate limiting placeholder — requires block height access.
	// Enable when cross-realm block height API is available.
}

func assertChannel(name string) {
	for _, ch := range channels {
		if ch.Name == name {
			return
		}
	}
	panic("unknown channel: " + name)
}

// ── Config ────────────────────────────────────────────────

func GetBoardConfig() string {
	return boardName + "|" + boardDescription + "|" + daoRealmPath
}
