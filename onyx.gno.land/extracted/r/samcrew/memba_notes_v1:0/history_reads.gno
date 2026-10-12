package memba_notes_v1

import "strconv"

func PublicHistoryInfoJSON(idHex string) string {
	id := historyID(idHex)
	h := historyGet(id)
	if h == nil {
		return "null"
	}
	n := h.Latest.State
	return `{"schema":"memba.notes.public-history-info/v1","id":` + q(idHex) + `,"start_state_revision":` + u(h.StartRevision) + `,"start_body_revision":` + u(h.StartBodyRevision) + `,"head_seq":` + u(h.Head) + `,"latest_state_revision":` + u(n.Revision) + `,"retention":"public-moderator-redactable","coverage":"public-since-publication-v1","deleted":` + strconv.FormatBool(n.Deleted) + `,"moderator_hidden":` + strconv.FormatBool(n.ModeratorHidden) + `}`
}
func historyEntryFields(e *historyEntry) string {
	proposal := "null"
	if e.Proposal != 0 {
		proposal = u(e.Proposal)
	}
	return `"seq":` + u(e.Seq) + `,"action":` + q(e.Action) + `,"height":` + q(strconv.FormatInt(e.Height, 10)) + `,"state_revision":` + u(e.Revision) + `,"actor":` + q(string(e.Actor)) + `,"executor":` + historyNullableText(string(e.Executor)) + `,"op_id":` + historyNullableID(e.Operation) + `,"proposal_id":` + proposal
}
func PublicHistoryJSON(idHex string, afterSeq, throughSeq uint64, limit int) string {
	id := historyID(idHex)
	if limit < 1 || limit > 20 {
		panic("notes: history page limit")
	}
	h := historyGet(id)
	if h == nil {
		return "null"
	}
	if throughSeq == 0 {
		if afterSeq != 0 {
			panic("notes: history first page cursor")
		}
		throughSeq = h.Head
	}
	if afterSeq > throughSeq || throughSeq > h.Head {
		panic("notes: history cursor")
	}
	items, next := "", "null"
	last, count := afterSeq, 0
	// Direct keys preserve contiguity without a scan or after+limit overflow.
	for last < throughSeq && count < limit {
		last++
		v, ok := historyEntries.Get(historyKey(id, last))
		if !ok {
			panic("notes: history gap")
		}
		e := v.(*historyEntry)
		if count > 0 {
			items += ","
		}
		items += "{" + historyEntryFields(e) + `,"comment_id":` + historyNullableID(e.Comment) + "}"
		count++
	}
	if last < throughSeq {
		next = u(last)
	}
	return `{"schema":"memba.notes.public-history-page/v1","id":` + q(idHex) + `,"through_seq":` + u(throughSeq) + `,"items":[` + items + `],"next_cursor":` + next + `}`
}
func PublicHistoryEntryJSON(idHex string, seq uint64) string {
	v, ok := historyEntries.Get(historyKey(historyID(idHex), seq))
	if !ok {
		return "null"
	}
	e := v.(*historyEntry)
	return `{"schema":"memba.notes.public-history-entry/v1","id":` + q(idHex) + "," + historyEntryFields(e) + `,"governance_action":` + historyNullableText(e.GovernanceAction) + `,"detail":` + e.Detail + `}`
}
func PublicHistoryVersionJSON(idHex string, stateRevision uint64) string {
	raw, ok := historyVersions.Get(historyKey(historyID(idHex), stateRevision))
	if !ok {
		return "null"
	}
	v := raw.(*historyVersion)
	n := v.State
	titleRevision, title, bodyRevision, bodyHash, bodyBytes := "null", "null", "null", "null", "0"
	titleRedacted, bodyRedacted := false, false
	if v.Title != nil {
		titleRevision, titleRedacted = u(n.TitleRevision), v.Title.Redacted
		if !titleRedacted {
			title = blob(v.Title.Bytes)
		}
	}
	if v.Body != nil {
		bodyRevision, bodyHash, bodyBytes, bodyRedacted = u(n.BodyRevision), q(v.Body.Hash), strconv.Itoa(len(v.Body.Bytes)), v.Body.Redacted
	}
	writers := ""
	for i, who := range n.Writers {
		if i > 0 {
			writers += ","
		}
		writers += q(string(who))
	}
	return `{"schema":"memba.notes.public-history-version/v1","id":` + q(idHex) + `,"state_revision":` + u(n.Revision) + `,"recorded_seq":` + u(v.Seq) + `,"owner":` + q(string(n.Owner)) + `,"pending_owner":` + historyNullableText(string(n.PendingOwner)) + `,"owner_is_realm":` + strconv.FormatBool(n.OwnerIsRealm) + `,"owner_generation":` + u(n.OwnerGeneration) + `,"mode":` + strconv.Itoa(int(n.Mode)) + `,"epoch":` + u(uint64(n.Epoch)) + `,"title_revision":` + titleRevision + `,"title_blob":` + title + `,"title_redacted":` + strconv.FormatBool(titleRedacted) + `,"body_revision":` + bodyRevision + `,"body_bytes":` + q(bodyBytes) + `,"body_sha256":` + bodyHash + `,"body_redacted":` + strconv.FormatBool(bodyRedacted) + `,"writers":[` + writers + `],"policies":{"read":` + q(n.Policies[0]) + `,"write":` + q(n.Policies[1]) + `,"comment":` + q(n.Policies[2]) + `},"gov_writers":` + strconv.FormatBool(n.GovWriters) + `,"allow_public_writes":` + strconv.FormatBool(v.PublicWrites) + `,"owner_listed":` + strconv.FormatBool(n.Listed) + `,"moderator_hidden":` + strconv.FormatBool(n.ModeratorHidden) + `,"deleted":` + strconv.FormatBool(n.Deleted) + `}`
}
func PublicHistoryBodyChunkJSON(idHex string, bodyRevision uint64, offset, limit int) string {
	id := historyID(idHex)
	if limit < 1 || limit > MaxBodyChunkBytes || offset < 0 {
		panic("notes: history chunk bounds")
	}
	v, ok := historyBlobs.Get("body:" + historyKey(id, bodyRevision))
	if !ok {
		return "null"
	}
	b := v.(*historyBlob)
	if b.Redacted {
		return "null"
	}
	if offset > len(b.Bytes) {
		panic("notes: history chunk bounds")
	}
	end := offset + limit
	if end > len(b.Bytes) {
		end = len(b.Bytes)
	}
	return `{"schema":"memba.notes.public-history-body/v1","id":` + q(idHex) + `,"body_revision":` + u(bodyRevision) + `,"sha256":` + q(b.Hash) + `,"offset":` + q(strconv.Itoa(offset)) + `,"total":` + q(strconv.Itoa(len(b.Bytes))) + `,"next_offset":` + q(strconv.Itoa(end)) + `,"chunk_blob":` + blob(b.Bytes[offset:end]) + `}`
}
func PublicHistoryCommentJSON(idHex, cidHex string) string {
	id, cid := historyID(idHex), historyID(cidHex)
	v, ok := historyComments.Get(commentKey(id, cid))
	if !ok {
		return "null"
	}
	h := v.(*historyComment)
	c := h.Initial
	return `{"schema":"memba.notes.public-history-comment/v1","id":` + q(idHex) + `,"comment_id":` + q(cidHex) + `,"content":{"author":` + q(string(c.Author)) + `,"created_height":` + q(strconv.FormatInt(c.CreatedHeight, 10)) + `,"epoch":` + u(uint64(c.Epoch)) + `,"anchor_blob":` + blob(c.Anchor) + `,"body_blob":` + blob(c.Body) + `,"reference":` + historyCommentDetail(&c, h) + `},"presentation":{"latest_seq":` + u(h.LatestSeq) + `,"deleted":` + strconv.FormatBool(h.Deleted) + `,"hidden":` + strconv.FormatBool(h.Hidden) + `,"resolved":` + strconv.FormatBool(h.Resolved) + `,"redacted":` + strconv.FormatBool(h.Redacted) + `}}`
}
