package agentmarketplace

import (
	"sort"
	"strconv"
	"strings"
)

// Input limits.
const (
	minNameLen      = 3
	maxNameLen      = 48
	minTitleLen     = 3
	maxTitleLen     = 80
	minDescLen      = 3
	maxDescLen      = 280
	maxNoteLen      = 80
	minTagLen       = 2
	maxTagLen       = 24
	maxTags         = 8
	maxTagsInputLen = 200
	maxRateUgnot    = 1000000000000 // 1,000,000 GNOT
	minBudgetUgnot  = 1
	maxBudgetUgnot  = 1000000000000
	ugnotPerGnot    = 1000000
	minScore        = 1
	maxScore        = 5
	maxCommentLen   = 120
	commitHashLen   = 64
	minRevealSecs   = 60
	maxRevealSecs   = 30 * 24 * 60 * 60
)

// isSafeChar is the character whitelist for every free-text field. It keeps
// user-supplied strings from injecting markdown, HTML, gnoweb tags or
// table pipes into Render output, and keeps them single-line.
func isSafeChar(c rune) bool {
	switch {
	case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
		return true
	}
	switch c {
	case ' ', '-', '.', ',', '(', ')', '\'', '/', '+', ':', '@', '#', '%', '&', '=':
		return true
	}
	return false
}

// checkText validates a free-text field and panics with a readable message.
func checkText(field, s string, minLen, maxLen int) {
	if len(s) < minLen || len(s) > maxLen {
		panic(field + " must be " + strconv.Itoa(minLen) + "-" + strconv.Itoa(maxLen) + " characters")
	}
	if s[0] == ' ' || s[len(s)-1] == ' ' {
		panic(field + " must not start or end with a space")
	}
	for _, c := range s {
		if !isSafeChar(c) {
			panic(field + " contains an unsupported character: only letters, digits, spaces and - . , ( ) ' / + : @ # % & = are allowed")
		}
	}
}

func checkRateKind(kind string) {
	switch kind {
	case RateHourly, RateFlat:
		return
	}
	panic("rate kind must be one of: hourly, flat")
}

func checkRate(rate int64) {
	if rate < 1 || rate > maxRateUgnot {
		panic("rate must be between 1 and " + strconv.FormatInt(maxRateUgnot, 10) + " ugnot")
	}
}

func checkBudget(budget int64) {
	if budget < minBudgetUgnot || budget > maxBudgetUgnot {
		panic("budget must be between " + strconv.FormatInt(minBudgetUgnot, 10) + " and " + strconv.FormatInt(maxBudgetUgnot, 10) + " ugnot")
	}
}

// checkSpecialty validates a single required specialty tag.
func checkSpecialty(tag string) string {
	normalized := strings.ToLower(strings.TrimSpace(tag))
	checkTag("specialty", normalized)
	return normalized
}

func checkTag(field, tag string) {
	if len(tag) < minTagLen || len(tag) > maxTagLen {
		panic(field + " must be " + strconv.Itoa(minTagLen) + "-" + strconv.Itoa(maxTagLen) + " characters")
	}
	if strings.Contains(tag, ",") {
		panic(field + " must be a single tag, not a comma-separated list")
	}
	if tag[0] == ' ' || tag[len(tag)-1] == ' ' {
		panic(field + " must not start or end with a space")
	}
	for _, c := range tag {
		if !isSafeChar(c) {
			panic(field + " contains an unsupported character: only letters, digits, spaces and - . , ( ) ' / + : @ # % & = are allowed")
		}
	}
}

// parseTags canonicalizes a comma-separated specialty list: lowercased,
// trimmed, unique, sorted, joined with ", ".
func parseTags(raw string) string {
	checkText("tags", raw, minTagLen, maxTagsInputLen)
	parts := strings.Split(raw, ",")
	var tags []string
	for _, p := range parts {
		tag := strings.ToLower(strings.TrimSpace(p))
		if tag == "" {
			continue
		}
		checkTag("tag", tag)
		if containsTag(tags, tag) {
			continue
		}
		tags = append(tags, tag)
		if len(tags) > maxTags {
			panic("an agent can list at most " + strconv.Itoa(maxTags) + " specialty tags")
		}
	}
	if len(tags) == 0 {
		panic("tags must list at least one specialty")
	}
	sort.Strings(tags)
	return strings.Join(tags, ", ")
}

func containsTag(tags []string, tag string) bool {
	for _, t := range tags {
		if t == tag {
			return true
		}
	}
	return false
}

func agentHasSpecialty(agentTags, specialty string) bool {
	for _, t := range strings.Split(agentTags, ", ") {
		if t == specialty {
			return true
		}
	}
	return false
}

func checkScore(score int) {
	if score < minScore || score > maxScore {
		panic("score must be an integer from 1 to 5")
	}
}

func checkComment(comment string) {
	if comment == "" {
		return
	}
	checkText("comment", comment, 1, maxCommentLen)
}

func checkCommitHash(h string) string {
	h = strings.ToLower(h)
	if len(h) != commitHashLen {
		panic("commit hash must be a 64-character hex SHA-256 digest")
	}
	for _, c := range h {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			panic("commit hash must be a 64-character hex SHA-256 digest")
		}
	}
	return h
}

func checkRevealDeadline(secs int64) {
	if secs < minRevealSecs || secs > maxRevealSecs {
		panic("reveal deadline must be between 60 seconds and 30 days")
	}
}
