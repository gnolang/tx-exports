package sealedpost

import (
	"chain/runtime"
	"strconv"
	"strings"
)

// realmWebPath is this realm's path as served by gnoweb; render arguments
// (the string handed to Render) are appended after a ":".
const realmWebPath = "/r/g1gu8mdvjg8l5wj2ytknhs7pmyu0rmeclyvvlsd8/sealedpost"

// Render serves the realm's gnoweb pages:
//
//	""               home: every capsule, newest first
//	"capsule/<id>"   a single capsule in full
func Render(path string) string {
	path = strings.Trim(path, "/")
	if path == "" {
		return renderHome()
	}
	if strings.HasPrefix(path, "capsule/") {
		id, err := strconv.ParseUint(strings.TrimPrefix(path, "capsule/"), 10, 64)
		if err != nil || id == 0 || id > uint64(len(capsules)) {
			return "# Sealed Post\n\nCapsule not found.\n\n[Back to all capsules](" + realmWebPath + ")\n"
		}
		return renderCapsule(capsules[id-1])
	}
	return "# Sealed Post\n\nPage not found.\n\n[Back to all capsules](" + realmWebPath + ")\n"
}

func renderHome() string {
	var b strings.Builder
	b.WriteString("# Sealed Post\n\n")
	b.WriteString("Time capsules for messages to the future. A capsule stores only a title " +
		"and a SHA-256 commitment to a secret message. The message is revealed — and " +
		"cryptographically verified against the commitment — once its unlock block arrives.\n\n")
	b.WriteString("Current block height: " + strconv.FormatInt(runtime.ChainHeight(), 10) + "\n\n")
	if len(capsules) == 0 {
		b.WriteString("No capsules yet. Seal the first one!\n")
		return b.String()
	}
	b.WriteString("## Capsules\n\n")
	for i := len(capsules) - 1; i >= 0; i-- {
		b.WriteString(capsuleSummary(capsules[i]))
	}
	return b.String()
}

func capsuleSummary(c *Capsule) string {
	var b strings.Builder
	b.WriteString("### [" + strconv.FormatUint(c.ID, 10) + ". " + c.Title + "](" +
		realmWebPath + ":capsule/" + strconv.FormatUint(c.ID, 10) + ")\n\n")
	b.WriteString("By " + c.Author.String())
	if c.Recipient != address("") {
		b.WriteString(", for " + c.Recipient.String())
	}
	b.WriteString("\n\n")
	if c.Revealed {
		b.WriteString("> " + c.RevealedText + "\n\n")
	} else {
		remaining := c.UnlockHeight - runtime.ChainHeight()
		if remaining < 0 {
			remaining = 0
		}
		b.WriteString("Sealed until block " + strconv.FormatInt(c.UnlockHeight, 10) +
			" (" + strconv.FormatInt(remaining, 10) + " blocks to go).\n\n")
	}
	return b.String()
}

func renderCapsule(c *Capsule) string {
	var b strings.Builder
	b.WriteString("# " + c.Title + "\n\n")
	b.WriteString("- Capsule: " + strconv.FormatUint(c.ID, 10) + "\n")
	b.WriteString("- Author: " + c.Author.String() + "\n")
	if c.Recipient != address("") {
		b.WriteString("- For: " + c.Recipient.String() + "\n")
	}
	b.WriteString("- Sealed at block: " + strconv.FormatInt(c.CreatedHeight, 10) + "\n")
	b.WriteString("- Unlock block: " + strconv.FormatInt(c.UnlockHeight, 10) + "\n")
	b.WriteString("- Commitment: `" + c.Commitment + "`\n\n")
	if c.Revealed {
		b.WriteString("## Revealed message\n\n")
		b.WriteString("> " + c.RevealedText + "\n")
	} else {
		remaining := c.UnlockHeight - runtime.ChainHeight()
		if remaining < 0 {
			remaining = 0
		}
		b.WriteString("This capsule is still sealed. " +
			strconv.FormatInt(remaining, 10) + " blocks to go.\n")
	}
	b.WriteString("\n[Back to all capsules](" + realmWebPath + ")\n")
	return b.String()
}
