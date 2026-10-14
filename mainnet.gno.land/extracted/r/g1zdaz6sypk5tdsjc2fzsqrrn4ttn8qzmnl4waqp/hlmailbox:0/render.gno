package hlmailbox

import (
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/g1zdaz6sypk5tdsjc2fzsqrrn4ttn8qzmnl4waqp/decisions/v0"
	hl "gno.land/p/g1zdaz6sypk5tdsjc2fzsqrrn4ttn8qzmnl4waqp/hyperlane/v0"
)

const (
	pageMax      = 20 // messages a "msgs/" page holds
	verifiersMax = 20 // registered verifier paths (and announced successors) the page and "json" name, and a "verifiers/" ("successors/") page holds
)

// Render:
//
//	""                  the mailbox's page: the launch values live or waiting, verifiers, signers, seats, flags
//	"decisions"         the decisions page: the last 100 pending and executed per kind
//	"json"              domain, hook, count, root, live, signers, verifiers (the first 20 registered paths and the
//	                    count), seats, flags, routes (each with its predecessor and successor, and the height and
//	                    time of the kind 6 that enrolled it on Solana: enrolled, enrolledAt), successors (the
//	                    first 20 announced paths, the count, and successorRoutes: the route each announced for),
//	                    for the agents
//	"decisions.json"    every decision, as a JSON array
//	"msg/<nonce>"       one dispatched message: {"nonce","id","root","height","message"}; "null" if none
//	"msgs/<from>"       up to 20 messages from nonce <from> on, as a JSON array
//	"verifiers/<from>"  up to 20 registered verifier paths from offset <from> on, in path order, as a JSON array
//	"successors/<from>" up to 20 announced successor paths from offset <from> on, in path order, as a JSON array
//	"delivered/<id>"    the block height a message id (hex) was delivered at here, 0 if never
func Render(path string) string {
	switch {
	case path == "":
		return page()
	case path == "decisions":
		return "# Decisions\n\n" + ledger.Page()
	case path == "json":
		return summaryJSON()
	case path == "decisions.json":
		return ledger.JSON()
	case strings.HasPrefix(path, "msg/"):
		n, ok := parseNonce(path[len("msg/"):])
		if !ok {
			return "null"
		}
		return msgJSON(n)
	case strings.HasPrefix(path, "msgs/"):
		from, ok := parseNonce(path[len("msgs/"):])
		if !ok {
			return "[]"
		}
		var b strings.Builder
		b.WriteString("[")
		for i := uint32(0); i < pageMax && uint64(from)+uint64(i) < uint64(tree.Count); i++ {
			if i > 0 {
				b.WriteString(",")
			}
			b.WriteString(msgJSON(from + i))
		}
		b.WriteString("]")
		return b.String()
	case strings.HasPrefix(path, "verifiers/"):
		from, ok := parseNonce(path[len("verifiers/"):])
		if !ok {
			return "[]"
		}
		return pathsJSON(&verifiers, int(from))
	case strings.HasPrefix(path, "successors/"):
		from, ok := parseNonce(path[len("successors/"):])
		if !ok {
			return "[]"
		}
		return pathsJSON(&successors, int(from))
	case strings.HasPrefix(path, "delivered/"):
		return strconv.FormatInt(Delivered(path[len("delivered/"):]), 10)
	}
	return "unknown path; see the mailbox's page"
}

func parseNonce(s string) (uint32, bool) {
	n, err := strconv.ParseUint(s, 10, 32)
	return uint32(n), err == nil
}

func q(s string) string { return strconv.Quote(s) }

func msgJSON(n uint32) string {
	v := sent.Get(nonceKey(n))
	if v == nil {
		return "null"
	}
	s := v.(*sentMsg)
	id := hl.ID([]byte(s.raw))
	return "{\"nonce\":" + u32(n) + ",\"id\":" + q(hx(id[:])) + ",\"root\":" + q(hx(s.root[:])) +
		",\"height\":" + strconv.FormatInt(s.height, 10) + ",\"message\":" + q(hx([]byte(s.raw))) + "}"
}

func keysJSON(ks []Key) string {
	parts := make([]string, len(ks))
	for i, k := range ks {
		parts[i] = q(hx(k[:]))
	}
	return "[" + strings.Join(parts, ",") + "]"
}

// pathsJSON is up to verifiersMax keys of a tree of pkgpaths (the registered verifiers, the announced successors)
// from offset from on, in path order: the listing is bounded whatever the count, since nothing is ever removed.
func pathsJSON(t *avl.Tree, from int) string {
	var b strings.Builder
	b.WriteString("[")
	first := true
	t.IterateByOffset(from, verifiersMax, func(k string, _ any) bool {
		if !first {
			b.WriteString(",")
		}
		first = false
		b.WriteString(q(k))
		return false
	})
	b.WriteString("]")
	return b.String()
}

// pathsLine is a tree of pkgpaths on the page: the first verifiersMax in path order and, past them, where the rest
// are (page is the Render path that pages them); "none" for an empty tree.
func pathsLine(t *avl.Tree, page string) string {
	n := t.Size()
	if n == 0 {
		return "none"
	}
	var b strings.Builder
	i := 0
	t.IterateByOffset(0, verifiersMax, func(k string, _ any) bool {
		if i > 0 {
			b.WriteString(", ")
		}
		i++
		b.WriteString("`" + k + "`")
		return false
	})
	if n > verifiersMax {
		m := strconv.Itoa(verifiersMax)
		b.WriteString(", … (the first " + m + "; the rest at [" + page + "/" + m + "](" + pkgPathLink() + ":" + page + "/" + m + "))")
	}
	return b.String()
}

func summaryJSON() string {
	var b strings.Builder
	b.WriteString("{\"domain\":" + u32(localDomain) + ",\"hook\":" + q(Hook()) + ",\"address\":" + q(string(Address())) +
		",\"count\":" + u32(tree.Count) + ",\"root\":" + q(Root()) + ",\"delivered\":" + strconv.Itoa(done.Size()) +
		",\"live\":" + strconv.FormatBool(live) + ",\"launchedAt\":" + strconv.FormatInt(launchedAt, 10) +
		"," + decisions.GovernorJSON(launchGovernor, yielded) +
		",\"launchOrigin\":" + u32(launchOrigin) + ",\"clocks\":" + decisions.ClocksJSON() + ",\"decisions\":" + strconv.FormatInt(ledger.Last(), 10) +
		",\"signers\":{\"keys\":" + keysJSON(signerKeys) + ",\"threshold\":" + strconv.Itoa(signerRule.Threshold) +
		",\"groupA\":" + keysJSON(signerRule.GroupA) + ",\"groupB\":" + keysJSON(signerRule.GroupB) + "}" +
		",\"verifiers\":{")
	first := true
	active.Iterate("", "", func(k string, v any) bool {
		origin, _ := strconv.ParseUint(k, 10, 32)
		if !first {
			b.WriteString(",")
		}
		first = false
		b.WriteString(q(strconv.FormatUint(origin, 10)) + ":{\"pkgpath\":" + q(v.(string)) + ",\"registered\":" + strconv.FormatBool(verifiers.Has(v.(string))) + "}")
		return false
	})
	b.WriteString("},\"registered\":" + pathsJSON(&verifiers, 0) + ",\"registeredCount\":" + strconv.Itoa(verifiers.Size()) + ",\"seats\":[")
	for i := 1; i <= seatCount; i++ {
		if i > 1 {
			b.WriteString(",")
		}
		b.WriteString(q(string(seats[i])))
	}
	b.WriteString("],\"routes\":{")
	first = true
	routes.Iterate("", "", func(k string, v any) bool {
		r := v.(*routeRec)
		if !first {
			b.WriteString(",")
		}
		first = false
		b.WriteString(q(k) + ":{\"epoch\":" + strconv.FormatInt(r.epoch, 10) + ",\"epochAt\":" + strconv.FormatInt(r.epochAt, 10) +
			",\"sends\":" + strconv.FormatBool(Paused(k, FnSends)) + ",\"credits\":" + strconv.FormatBool(Paused(k, FnCredits)) +
			",\"payouts\":" + strconv.FormatBool(Paused(k, FnPayouts)) + ",\"flags\":[")
		for i, f := range Flags(k) {
			if i > 0 {
				b.WriteString(",")
			}
			b.WriteString(q(f))
		}
		b.WriteString("],\"predecessor\":" + q(r.predecessor) + ",\"successor\":" + q(r.successor) +
			",\"enrolled\":" + strconv.FormatInt(r.enrolled, 10) + ",\"enrolledAt\":" + strconv.FormatInt(r.enrolledAt, 10) +
			",\"pulled\":" + strconv.FormatBool(r.pulled) + ",\"dropped\":" + quotedJSON(r.dropped) + "}")
		return false
	})
	b.WriteString("},\"droppedRoutes\":" + droppedRoutesJSON() + ",\"successors\":" + pathsJSON(&successors, 0) + ",\"successorCount\":" + strconv.Itoa(successors.Size()) + ",\"successorRoutes\":" + successorRoutesJSON() + "}")
	return b.String()
}

// quotedJSON is a list of strings as a JSON array.
func quotedJSON(ss []string) string {
	parts := make([]string, len(ss))
	for i, s := range ss {
		parts[i] = q(s)
	}
	return "[" + strings.Join(parts, ",") + "]"
}

// droppedRoutesJSON is every dropped successor (R35) with the predecessor whose re-point dropped it, as an object
// of pkgpath → pkgpath: the tombstones, bounded by the migrations a bridge sees in its life.
func droppedRoutesJSON() string {
	var b strings.Builder
	b.WriteString("{")
	first := true
	droppedRoutes.Iterate("", "", func(k string, v any) bool {
		if !first {
			b.WriteString(",")
		}
		first = false
		b.WriteString(q(k) + ":" + q(v.(string)))
		return false
	})
	b.WriteString("}")
	return b.String()
}

// droppedLine is the dropped successors on the page, each with the predecessor that re-pointed away from it; ""
// when none.
func droppedLine() string {
	if droppedRoutes.Size() == 0 {
		return ""
	}
	var parts []string
	droppedRoutes.Iterate("", "", func(k string, v any) bool {
		parts = append(parts, "`"+k+"` (by `"+v.(string)+"`)")
		return false
	})
	return "- dropped (routes no more, re-pointed away): " + strings.Join(parts, ", ") + "\n"
}

// successorRoutesJSON is the first verifiersMax announced successors with the route each announced for (AQ5), as
// an object of pkgpath → "GNOT" or "BUBBLE".
func successorRoutesJSON() string {
	var b strings.Builder
	b.WriteString("{")
	first := true
	successors.IterateByOffset(0, verifiersMax, func(k string, v any) bool {
		if !first {
			b.WriteString(",")
		}
		first = false
		b.WriteString(q(k) + ":" + q(v.(string)))
		return false
	})
	b.WriteString("}")
	return b.String()
}

// successorsLine is the announced successors on the page, each with the route it announced for (AQ5): the first
// verifiersMax in path order and, past them, where the rest are; "none" for an empty tree.
func successorsLine() string {
	n := successors.Size()
	if n == 0 {
		return "none"
	}
	var b strings.Builder
	i := 0
	successors.IterateByOffset(0, verifiersMax, func(k string, v any) bool {
		if i > 0 {
			b.WriteString(", ")
		}
		i++
		b.WriteString("`" + k + "` (" + v.(string) + ")")
		return false
	})
	if n > verifiersMax {
		m := strconv.Itoa(verifiersMax)
		b.WriteString(", … (the first " + m + "; the rest at [successors/" + m + "](" + pkgPathLink() + ":successors/" + m + "))")
	}
	return b.String()
}

func page() string {
	var b strings.Builder
	b.WriteString("# The bridge's mailbox\n\n")
	b.WriteString("gno.land's end of the GNOT and BUBBLE bridge to Solana: messages out to Solana (the Dispatch event the light client proves), and in from it under the active verifier. Every setting here moves only by a decision made with this realm's builders — the governor's own until it yields, a GovDAO proposal after; the guardians and watch keys can only pause.\n\n")
	if live {
		b.WriteString("- **live** since " + strconv.FormatInt(launchedAt, 10) + " (the Launch decision executed)\n")
	} else {
		b.WriteString("- **not launched**: the values below are the compiled launch values, waiting for the Launch decision; the routes refuse sends and credits. A passed Launch executes within 14 days of its proposal, like every decision; one nobody executed by then lapses and is proposed again\n")
	}
	b.WriteString("- " + decisions.GovernorLine(launchGovernor, yielded) + "\n")
	b.WriteString("- a proposal made with a builder (of this realm, a route, r/hlfees or r/hlgov) is executed with r/gov/dao's `ExecuteOrRejectProposal`: the one error a closure returns — the 14-day deadline — then denies it for good; under `ExecuteProposal` that error reverts the transaction instead and the proposal stands, every retry failing the same way. Anything else a closure refuses is a panic, which leaves the proposal for a retry under either call\n")
	b.WriteString("- domain: " + u32(localDomain) + "; Solana: " + u32(launchOrigin) + "\n")
	b.WriteString("- " + decisions.Clocks() + "\n")
	b.WriteString("- merkle tree hook: `" + Hook() + "`\n")
	b.WriteString("- messages out: " + u32(tree.Count) + ", root `" + Root() + "`; in: " + strconv.Itoa(done.Size()) + "\n")
	b.WriteString("- decisions: " + strconv.FormatInt(ledger.Last(), 10) + " ([page](" + pkgPathLink() + ":decisions))\n")
	b.WriteString("\n## Verifiers\n\n")
	active.Iterate("", "", func(k string, v any) bool {
		origin, _ := strconv.ParseUint(k, 10, 32)
		note := ""
		if !verifiers.Has(v.(string)) {
			note = " (**not registered**: nothing from this origin is taken until it is)"
		}
		b.WriteString("- from " + strconv.FormatUint(origin, 10) + ": `" + v.(string) + "`" + note + "\n")
		return false
	})
	b.WriteString("- registered (" + strconv.Itoa(verifiers.Size()) + "): " + pathsLine(&verifiers, "verifiers"))
	b.WriteString("\n\n## Signers\n\n- rule: " + signerRule.String() + "\n")
	for i, k := range signerKeys {
		b.WriteString("- " + strconv.Itoa(i) + ": `" + hx(k[:]) + "`\n")
	}
	b.WriteString("\n## Seats\n\n")
	for i := 1; i <= seatCount; i++ {
		kind := "guardian"
		if !IsGuardianSeat(i) {
			kind = "watch key"
		}
		a := string(seats[i])
		if a == "" {
			a = "(empty)"
		}
		b.WriteString("- seat " + strconv.Itoa(i) + " (" + kind + "): " + a + "\n")
	}
	b.WriteString("\n## Routes and flags\n\n")
	routes.Iterate("", "", func(k string, v any) bool {
		r := v.(*routeRec)
		b.WriteString("- `" + k + "`: payouts epoch " + strconv.FormatInt(r.epoch, 10))
		if r.predecessor != "" {
			b.WriteString(", successor of `" + r.predecessor + "`")
		}
		if r.pulled {
			b.WriteString(", page 0 pulled")
		}
		if r.successor != "" {
			b.WriteString(", migrated to `" + r.successor + "`")
		}
		if len(r.dropped) > 0 {
			b.WriteString(", dropped `" + strings.Join(r.dropped, "`, `") + "`")
		}
		if r.enrolled != 0 {
			b.WriteString(", enrolled on Solana by kind 6 at height " + strconv.FormatInt(r.enrolled, 10) + " (" + strconv.FormatInt(r.enrolledAt, 10) + ")")
		}
		fs := Flags(k)
		if len(fs) == 0 {
			b.WriteString(", no flag\n")
		} else {
			b.WriteString("\n")
			for _, f := range fs {
				b.WriteString("  - **paused** " + f + "\n")
			}
		}
		return false
	})
	b.WriteString(droppedLine())
	b.WriteString("- successors announced (" + strconv.Itoa(successors.Size()) + "): " + successorsLine() + " (a route's migrate names only one of them, announced for its own route)\n")
	if tree.Count > 0 {
		b.WriteString("\n## Latest out\n\n")
		sent.ReverseIterateByOffset(0, 10, func(k string, v any) bool {
			s := v.(*sentMsg)
			m, _ := hl.ParseMessage([]byte(s.raw))
			id := hl.ID([]byte(s.raw))
			b.WriteString("- #" + u32(m.Nonce) + " to " + u32(m.Destination) + " at block " + strconv.FormatInt(s.height, 10) + ": `" + hx(id[:]) + "`\n")
			return false
		})
	}
	return b.String()
}

func pkgPathLink() string { return strings.TrimPrefix(pkgPath, "gno.land") }
