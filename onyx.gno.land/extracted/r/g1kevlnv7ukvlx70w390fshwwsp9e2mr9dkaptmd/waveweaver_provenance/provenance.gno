package waveweaver_provenance

import (
	"chain"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

const (
	// MinAntiSlopQAPermille enforces WaveWeaver Stage 6 Golden Set QA >= 85.0% (850/1000).
	MinAntiSlopQAPermille = 850
	AnchoredEvent         = "WaveWeaverProvenanceAnchored"
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
	pubsByID      avl.Tree // id -> *Publication
	pubsByDigest  avl.Tree // 64-char hex sha256 -> *Publication
	pubsBySeq     avl.Tree // zero-padded seq -> *Publication
	channelCounts avl.Tree // channelSlug -> int
	nextSeq       int
)

func normalizeSha256(raw string) string {
	s := strings.ToLower(strings.TrimSpace(raw))
	if strings.HasPrefix(s, "0x") {
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
	s := strings.TrimSpace(raw)
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
	whole := p / 10
	frac := p % 10
	return ufmt.Sprintf("%d.%d", whole, frac)
}

func jsonEscape(s string) string {
	out := strings.ReplaceAll(s, "\\", "\\\\")
	out = strings.ReplaceAll(out, "\"", "\\\"")
	out = strings.ReplaceAll(out, "\n", " ")
	out = strings.ReplaceAll(out, "\r", " ")
	return out
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
	cleanID := cleanSlug(id)
	cleanCh := cleanSlug(channelSlug)
	cleanTitle := strings.TrimSpace(title)
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

	cleanFormats := strings.TrimSpace(formatsCSV)
	if cleanFormats == "" {
		cleanFormats = "9:16_AVATAR_VIDEO,VISUAL_CAROUSEL,LONG_ARTICLE,PODCAST_AUDIO,MICRO_THREAD"
	}
	cleanSummary := strings.TrimSpace(summaryMarkdown)
	if len(cleanSummary) > 1200 {
		cleanSummary = cleanSummary[:1200]
	}

	caller := cur.Previous().Address()
	nextSeq++
	pub := &Publication{
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
	pubsByDigest.Set(normHash, pub)
	pubsBySeq.Set(padSeq(nextSeq), pub)

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

	return ufmt.Sprintf("ANCHORED:%s:0x%s:QA=%s", cleanID, normHash, formatPermille(qaScorePermille))
}

// VerifyDigest allows AI agents (via gnomcp) and readers to verify a SHA-256 content digest without gas.
func VerifyDigest(sha256Digest string) string {
	s := strings.ToLower(strings.TrimSpace(sha256Digest))
	if strings.HasPrefix(s, "0x") {
		s = s[2:]
	}
	if len(s) != 64 {
		return `{"verified":false,"error":"invalid_sha256_length"}`
	}
	raw := pubsByDigest.Get(s)
	if raw == nil {
		return ufmt.Sprintf(`{"verified":false,"sha256":"0x%s"}`, s)
	}
	pub := raw.(*Publication)
	return ufmt.Sprintf(
		`{"verified":true,"seq":%d,"id":"%s","channel":"%s","title":"%s","sha256":"0x%s","qa_score":"%s","citations":%d,"slop_removed":%d,"author":"%s"}`,
		pub.Seq,
		jsonEscape(pub.ID),
		jsonEscape(pub.ChannelSlug),
		jsonEscape(pub.Title),
		pub.Sha256Digest,
		formatPermille(pub.QAScorePermille),
		pub.CitationCount,
		pub.SlopRemovedCount,
		pub.Author.String(),
	)
}

// TotalPublications returns the total count of verified publications anchored in this realm.
func TotalPublications() int {
	return pubsByID.Size()
}

// ChannelCount returns the number of isolated WaveWeaver content channels with anchored records.
func ChannelCount() int {
	return channelCounts.Size()
}

// Render serves native gnoweb Markdown views:
//   - ""                  -> Registry dashboard, channel isolation summary & verified publications
//   - "channel/<slug>"    -> Channel-scoped publications
//   - "pub/<id>"          -> Full provenance certificate for a single publication
//   - "verify/<sha256>"   -> Direct SHA-256 digest lookup
func Render(path string) string {
	cleanPath := strings.Trim(path, "/")
	if strings.HasPrefix(cleanPath, "pub/") {
		return renderPublicationDetail(strings.TrimPrefix(cleanPath, "pub/"))
	}
	if strings.HasPrefix(cleanPath, "channel/") {
		return renderDashboard(strings.TrimPrefix(cleanPath, "channel/"))
	}
	if strings.HasPrefix(cleanPath, "verify/") {
		return renderVerify(strings.TrimPrefix(cleanPath, "verify/"))
	}
	return renderDashboard("")
}

func renderDashboard(filterChannel string) string {
	var b strings.Builder
	b.WriteString("# WaveWeaver — On-Chain Anti-AI-Slop Content Provenance Registry\n\n")
	b.WriteString("> **8-Stage Human-in-the-Loop AI Media OS**: Stage 5 Anti-AI-Slop Calibration + Stage 6 Golden Set QA Gate (`>= 85.0`) + Stage 8 `SHA-256` Provenance Realm.\n\n")
	b.WriteString(ufmt.Sprintf(
		"- **Verified Publications Anchored**: `%d`  \n- **Isolated Content Channels**: `%d`  \n- **Deterministic On-Chain Gate**: `QAScore >= 85.0` & `Primary Citations >= 1`\n\n",
		pubsByID.Size(),
		channelCounts.Size(),
	))

	if channelCounts.Size() > 0 {
		b.WriteString("## Isolated Multi-Tenant Channels (`Org -> Workspace -> ContentChannel`)\n\n")
		channelCounts.Iterate("", "", func(chKey string, val any) bool {
			cnt := val.(int)
			b.WriteString(ufmt.Sprintf("- **`%s`** (`%d` verified releases) — [Filter Channel](?:/channel/%s)\n", chKey, cnt, chKey))
			return false
		})
		if filterChannel != "" {
			b.WriteString(ufmt.Sprintf("\n*Showing channel filter: `%s` — [Back to All Channels](?:)*\n", filterChannel))
		}
		b.WriteString("\n")
	}

	b.WriteString("## Anchored Content Provenance Ledger\n\n")
	if pubsBySeq.Size() == 0 {
		b.WriteString("*No publications anchored yet.*\n")
		return b.String()
	}

	b.WriteString("| # | Publication ID | Channel | Title | Anti-Slop QA | Citations | SHA-256 Digest |\n")
	b.WriteString("| :--- | :--- | :--- | :--- | :--- | :--- | :--- |\n")

	pubsBySeq.ReverseIterate("", "", func(_ string, val any) bool {
		pub := val.(*Publication)
		if filterChannel != "" && pub.ChannelSlug != filterChannel {
			return false
		}
		shortHash := pub.Sha256Digest[:10] + "..." + pub.Sha256Digest[56:]
		b.WriteString(ufmt.Sprintf(
			"| %d | [`%s`](?:/pub/%s) | `%s` | %s | **%s / 100** (`-%d` slop) | `%d` | `0x%s` |\n",
			pub.Seq,
			pub.ID,
			pub.ID,
			pub.ChannelSlug,
			pub.Title,
			formatPermille(pub.QAScorePermille),
			pub.SlopRemovedCount,
			pub.CitationCount,
			shortHash,
		))
		return false
	})

	return b.String()
}

func renderPublicationDetail(id string) string {
	raw := pubsByID.Get(strings.TrimSpace(id))
	if raw == nil {
		return ufmt.Sprintf("# Publication Not Found\n\nNo anchored publication matches ID `%s`.\n", id)
	}
	pub := raw.(*Publication)
	var b strings.Builder
	b.WriteString(ufmt.Sprintf("# Provenance Certificate · `%s`\n\n", pub.ID))
	b.WriteString(ufmt.Sprintf("- **Title**: %s\n", pub.Title))
	b.WriteString(ufmt.Sprintf("- **Isolated Channel**: `%s`\n", pub.ChannelSlug))
	b.WriteString(ufmt.Sprintf("- **Canonical SHA-256 Digest**: `0x%s`\n", pub.Sha256Digest))
	b.WriteString(ufmt.Sprintf("- **Stage 6 Golden Set QA Score**: **`%s / 100.0`** (`%d` LLM slop clichés stripped)\n", formatPermille(pub.QAScorePermille), pub.SlopRemovedCount))
	b.WriteString(ufmt.Sprintf("- **Verified Primary Citations**: `%d`\n", pub.CitationCount))
	b.WriteString(ufmt.Sprintf("- **5 Synchronized Media Formats**: `%s`\n", pub.FormatsCSV))
	b.WriteString(ufmt.Sprintf("- **Anchored By**: `%s`\n\n", pub.Author.String()))
	if pub.SummaryMarkdown != "" {
		b.WriteString("## Calibrated Executive Summary\n\n")
		b.WriteString(pub.SummaryMarkdown + "\n\n")
	}
	b.WriteString("[<- Back to Provenance Registry](?:)\n")
	return b.String()
}

func renderVerify(digest string) string {
	return "# SHA-256 Digest Verification\n\n```json\n" + VerifyDigest(digest) + "\n```\n\n[<- Back to Provenance Registry](?:)\n"
}
