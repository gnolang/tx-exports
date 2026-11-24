package waveweaver_provenance_v1

import (
	"chain"
	"strconv"

	"gno.land/p/nt/avl/v0"
)

const (
	// MinAntiSlopQAPermille enforces WaveWeaver Stage 6 Golden Set QA >= 85.0% (850/1000).
	MinAntiSlopQAPermille = 850
	AnchoredEvent         = "WaveWeaverProvenanceAnchored"
	maxSummaryLen         = 1200
	lowerHexAlpha         = "abcdef"
)

// Publication represents an audited, anti-AI-slop calibrated media release anchored on-chain.
type Publication struct {
	Seq              int
	ID               string
	ChannelSlug      string
	Title            string
	Sha256Digest     string
	QAScorePermille  int
	SlopRemovedCount int
	CitationCount    int
	FormatsCSV       string
	SummaryMarkdown  string
	Author           address
}

var (
	pubsByID      avl.Tree // id -> Publication (value struct)
	pubsByDigest  avl.Tree // 64-char hex sha256 -> id (string)
	pubsBySeq     avl.Tree // zero-padded seq -> id (string)
	channelCounts avl.Tree // channelSlug -> int
	nextSeq       int
)

func trimSpaces(s string) string {
	start := 0
	for start < len(s) && (s[start] == ' ' || s[start] == '\t' || s[start] == '\n' || s[start] == '\r') {
		start++
	}
	end := len(s)
	for end > start && (s[end-1] == ' ' || s[end-1] == '\t' || s[end-1] == '\n' || s[end-1] == '\r') {
		end--
	}
	return s[start:end]
}

func toLowerHex(s string) string {
	out := ""
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c >= 'A' && c <= 'F' {
			idx := int(c - 'A')
			out += lowerHexAlpha[idx : idx+1]
		} else {
			out += s[i : i+1]
		}
	}
	return out
}

func normalizeSha256(raw string) string {
	s := toLowerHex(trimSpaces(raw))
	if len(s) >= 2 && s[:2] == "0x" {
		s = s[2:]
	}
	if len(s) != 64 {
		panic("waveweaver: sha256 digest must be 64 hex characters")
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			panic("waveweaver: sha256 digest contains non-hex character")
		}
	}
	return s
}

func cleanSlug(raw string) string {
	s := trimSpaces(raw)
	if s == "" || len(s) > 64 {
		panic("waveweaver: invalid identifier or channel slug")
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_'
		if !ok {
			panic("waveweaver: slug may only contain [a-zA-Z0-9_-]")
		}
	}
	return s
}

func padSeq(n int) string {
	s := strconv.Itoa(n)
	for len(s) < 6 {
		s = "0" + s
	}
	return s
}

func formatPermille(p int) string {
	return strconv.Itoa(p/10) + "." + strconv.Itoa(p%10)
}

func quote(s string) string {
	out := "\""
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c == '\\' || c == '"' {
			out += "\\" + s[i:i+1]
		} else if c == '\n' || c == '\r' {
			out += " "
		} else {
			out += s[i : i+1]
		}
	}
	return out + "\""
}

// AnchorPublication enforces deterministic Anti-AI-Slop & citation invariants before committing on-chain provenance.
func AnchorPublication(
	cur realm,
	id string,
	channelSlug string,
	title string,
	sha256Digest string,
	qaScorePermille int,
	slopRemovedCount int,
	citationCount int,
	formatsCSV string,
	summaryMarkdown string,
) string {
	prev := cur.Previous()
	caller := prev.Address()
	if !caller.IsValid() {
		panic("waveweaver: invalid caller address")
	}

	cleanID := cleanSlug(id)
	cleanCh := cleanSlug(channelSlug)
	cleanTitle := trimSpaces(title)
	if cleanTitle == "" || len(cleanTitle) > 200 {
		panic("waveweaver: title must be 1..200 chars")
	}
	normHash := normalizeSha256(sha256Digest)

	if qaScorePermille < MinAntiSlopQAPermille || qaScorePermille > 1000 {
		panic("waveweaver: Stage 6 Anti-AI-Slop QA score below 850 permille (85.0%) minimum gate")
	}
	if slopRemovedCount < 0 {
		panic("waveweaver: slopRemovedCount must be non-negative")
	}
	if citationCount < 1 {
		panic("waveweaver: at least 1 verified primary-source citation is required")
	}
	if pubsByID.Has(cleanID) {
		panic("waveweaver: duplicate publication ID")
	}
	if pubsByDigest.Has(normHash) {
		panic("waveweaver: duplicate sha256 content digest already anchored")
	}

	cleanFormats := trimSpaces(formatsCSV)
	if cleanFormats == "" {
		cleanFormats = "9:16_AVATAR_VIDEO,VISUAL_CAROUSEL,LONG_ARTICLE,PODCAST_AUDIO,MICRO_THREAD"
	}
	cleanSummary := trimSpaces(summaryMarkdown)
	if len(cleanSummary) > maxSummaryLen {
		cleanSummary = cleanSummary[:maxSummaryLen]
	}

	nextSeq++
	pub := Publication{
		Seq:              nextSeq,
		ID:               cleanID,
		ChannelSlug:      cleanCh,
		Title:            cleanTitle,
		Sha256Digest:     normHash,
		QAScorePermille:  qaScorePermille,
		SlopRemovedCount: slopRemovedCount,
		CitationCount:    citationCount,
		FormatsCSV:       cleanFormats,
		SummaryMarkdown:  cleanSummary,
		Author:           caller,
	}

	pubsByID.Set(cleanID, pub)
	pubsByDigest.Set(normHash, cleanID)
	pubsBySeq.Set(padSeq(nextSeq), cleanID)

	prevCount := 0
	if v := channelCounts.Get(cleanCh); v != nil {
		prevCount = v.(int)
	}
	channelCounts.Set(cleanCh, prevCount+1)

	chain.Emit(
		AnchoredEvent,
		"id", cleanID,
		"channel", cleanCh,
		"sha256", normHash,
		"qa_permille", strconv.Itoa(qaScorePermille),
		"author", caller.String(),
	)

	return "ANCHORED:" + cleanID + ":0x" + normHash + ":QA=" + formatPermille(qaScorePermille)
}

// VerifyDigest allows AI agents (via gnomcp) and readers to verify a SHA-256 content digest without gas.
func VerifyDigest(sha256Digest string) string {
	s := toLowerHex(trimSpaces(sha256Digest))
	if len(s) >= 2 && s[:2] == "0x" {
		s = s[2:]
	}
	if len(s) != 64 {
		return `{"verified":false,"error":"invalid_sha256_length"}`
	}
	idVal := pubsByDigest.Get(s)
	if idVal == nil {
		return `{"verified":false,"sha256":"0x` + s + `"}`
	}
	raw := pubsByID.Get(idVal.(string))
	if raw == nil {
		return `{"verified":false,"sha256":"0x` + s + `"}`
	}
	pub := raw.(Publication)
	return `{"verified":true,"seq":` + strconv.Itoa(pub.Seq) +
		`,"id":` + quote(pub.ID) +
		`,"channel":` + quote(pub.ChannelSlug) +
		`,"title":` + quote(pub.Title) +
		`,"sha256":"0x` + pub.Sha256Digest + `"` +
		`,"qa_score":` + quote(formatPermille(pub.QAScorePermille)) +
		`,"citations":` + strconv.Itoa(pub.CitationCount) +
		`,"slop_removed":` + strconv.Itoa(pub.SlopRemovedCount) +
		`,"author":` + quote(pub.Author.String()) + `}`
}

// TotalPublications returns the total count of verified publications anchored in this realm.
func TotalPublications() int {
	return pubsByID.Size()
}

// ChannelCount returns the number of isolated WaveWeaver content channels with anchored records.
func ChannelCount() int {
	return channelCounts.Size()
}

// Render serves native gnoweb Markdown views.
func Render(path string) string {
	cleanPath := trimSpaces(path)
	for len(cleanPath) > 0 && cleanPath[0] == '/' {
		cleanPath = cleanPath[1:]
	}
	for len(cleanPath) > 0 && cleanPath[len(cleanPath)-1] == '/' {
		cleanPath = cleanPath[:len(cleanPath)-1]
	}
	if len(cleanPath) > 4 && cleanPath[:4] == "pub/" {
		return renderPublicationDetail(cleanPath[4:])
	}
	if len(cleanPath) > 8 && cleanPath[:8] == "channel/" {
		return renderDashboard(cleanPath[8:])
	}
	if len(cleanPath) > 7 && cleanPath[:7] == "verify/" {
		return renderVerify(cleanPath[7:])
	}
	return renderDashboard("")
}

func renderDashboard(filterChannel string) string {
	out := "# WaveWeaver — On-Chain Anti-AI-Slop Content Provenance Registry\n\n"
	out += "> **8-Stage Human-in-the-Loop AI Media OS**: Stage 5 Anti-AI-Slop Calibration + Stage 6 Golden Set QA Gate (`>= 85.0`) + Stage 8 `SHA-256` Provenance Realm.\n\n"
	out += "- **Verified Publications Anchored**: `" + strconv.Itoa(pubsByID.Size()) + "`  \n"
	out += "- **Isolated Content Channels**: `" + strconv.Itoa(channelCounts.Size()) + "`  \n"
	out += "- **Deterministic On-Chain Gate**: `QAScore >= 85.0` & `Primary Citations >= 1`\n\n"

	if channelCounts.Size() > 0 {
		out += "## Isolated Multi-Tenant Channels (`Org -> Workspace -> ContentChannel`)\n\n"
		channelCounts.Iterate("", "", func(chKey string, val any) bool {
			cnt := val.(int)
			out += "- **`" + chKey + "`** (`" + strconv.Itoa(cnt) + "` verified releases) — [Filter Channel](?:/channel/" + chKey + ")\n"
			return false
		})
		if filterChannel != "" {
			out += "\n*Showing channel filter: `" + filterChannel + "` — [Back to All Channels](?:)*\n"
		}
		out += "\n"
	}

	out += "## Anchored Content Provenance Ledger\n\n"
	if pubsBySeq.Size() == 0 {
		out += "*No publications anchored yet.*\n"
		return out
	}

	out += "| # | Publication ID | Channel | Title | Anti-Slop QA | Citations | SHA-256 Digest |\n"
	out += "| :--- | :--- | :--- | :--- | :--- | :--- | :--- |\n"

	pubsBySeq.ReverseIterate("", "", func(_ string, val any) bool {
		idStr := val.(string)
		raw := pubsByID.Get(idStr)
		if raw == nil {
			return false
		}
		pub := raw.(Publication)
		if filterChannel != "" && pub.ChannelSlug != filterChannel {
			return false
		}
		shortHash := pub.Sha256Digest[:10] + "..." + pub.Sha256Digest[56:]
		out += "| " + strconv.Itoa(pub.Seq) +
			" | [`" + pub.ID + "`](?:/pub/" + pub.ID + ")" +
			" | `" + pub.ChannelSlug + "`" +
			" | " + pub.Title +
			" | **" + formatPermille(pub.QAScorePermille) + " / 100** (`-" + strconv.Itoa(pub.SlopRemovedCount) + "` slop)" +
			" | `" + strconv.Itoa(pub.CitationCount) + "`" +
			" | `0x" + shortHash + "` |\n"
		return false
	})

	return out
}

func renderPublicationDetail(id string) string {
	raw := pubsByID.Get(trimSpaces(id))
	if raw == nil {
		return "# Publication Not Found\n\nNo anchored publication matches ID `" + id + "`.\n"
	}
	pub := raw.(Publication)
	out := "# Provenance Certificate · `" + pub.ID + "`\n\n"
	out += "- **Title**: " + pub.Title + "\n"
	out += "- **Isolated Channel**: `" + pub.ChannelSlug + "`\n"
	out += "- **Canonical SHA-256 Digest**: `0x" + pub.Sha256Digest + "`\n"
	out += "- **Stage 6 Golden Set QA Score**: **`" + formatPermille(pub.QAScorePermille) + " / 100.0`** (`" + strconv.Itoa(pub.SlopRemovedCount) + "` LLM slop clichés stripped)\n"
	out += "- **Verified Primary Citations**: `" + strconv.Itoa(pub.CitationCount) + "`\n"
	out += "- **5 Synchronized Media Formats**: `" + pub.FormatsCSV + "`\n"
	out += "- **Anchored By**: `" + pub.Author.String() + "`\n\n"
	if pub.SummaryMarkdown != "" {
		out += "## Calibrated Executive Summary\n\n" + pub.SummaryMarkdown + "\n\n"
	}
	out += "[<- Back to Provenance Registry](?:)\n"
	return out
}

func renderVerify(digest string) string {
	return "# SHA-256 Digest Verification\n\n```json\n" + VerifyDigest(digest) + "\n```\n\n[<- Back to Provenance Registry](?:)\n"
}
