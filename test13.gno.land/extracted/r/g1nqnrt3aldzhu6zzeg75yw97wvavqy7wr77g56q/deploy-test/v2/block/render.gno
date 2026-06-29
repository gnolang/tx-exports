package block

import (
	"net/url"
	"strconv"
	"strings"

	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/grc1155"
	"gno.land/p/jeronimoalbi/pager"
	"gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/admin"
)

func Render(iUrl string) string {
	assertMigrationStateAvailable()
	u, err := url.Parse(iUrl)
	if err != nil {
		return "404\n"
	}

	path := u.Path
	query := u.Query()

	switch {
	case path == "":
		return renderHome()
	case path == "blocks":
		return renderBlocksList(iUrl)
	case path == "block":
		return renderBlock(query.Get("id"), query.Get("page"))
	case path == "inventory":
		return renderInventory(query.Get("owner"))
	case path == "grc1155":
		return renderGRC1155(query.Get("id"), query.Get("owner"))
	default:
		return "404\n"
	}
}

func renderHome() string {
	output := `# Block

Welcome to the Block management system on Akkadia.

## What is Block?

Block is a GRC1155-based multi-token system where each block type represents a unique item in the game:

* **GRC1155 Token**: Each block type is a fungible token with supply limits
* **Mintable**: Users can mint blocks by paying the mint price
* **Tradeable**: Blocks can be transferred between users
* **Usable**: Blocks can be installed/uninstalled in chunks

## How Blocks Work

1. **System Blocks**: Admin creates system blocks (ID < 100000)
2. **User Blocks**: Users can create custom blocks (ID >= 100000)
3. **Minting**: Pay mint price to receive block tokens
4. **Usage**: Install blocks in chunks, uninstall to recover

## Config

`
	output += "* **List Limit**: " + strconv.Itoa(listLimit) + "\n"
	output += "* **Creator BPS**: " + strconv.Itoa(creatorBPS) + " (" + formatBPSPercentInt(creatorBPS) + ")\n"

	output += `
## Stats

`
	output += "* **Total Blocks**: " + strconv.Itoa(blockStore.Total()) + "\n"
	output += "* **Next Block ID**: " + uint32String(blockStore.NextID()) + "\n"

	output += `
## Quick Links

* [Browse All Blocks](./block:blocks)

## Search Block by ID

<gno-form path="block">
  <gno-input name="id" placeholder="Enter block ID" />
</gno-form>

## Search Inventory by Owner

<gno-form path="inventory">
  <gno-input name="owner" placeholder="Enter owner address" />
</gno-form>

## Check GRC1155 Balance

<gno-form path="grc1155">
  <gno-input name="id" placeholder="Enter block ID" />
  <gno-input name="owner" placeholder="Enter owner address" />
</gno-form>
`

	return output
}

// renderBlocksList renders a list of all blocks with pagination
func renderBlocksList(iUrl string) string {
	output := `# All Blocks

[← Home](./block:)

`
	if blockStore.Total() == 0 {
		output += "*No blocks created yet.*\n"
		return output
	}

	pages, err := pager.New(iUrl, blockStore.Total(), pager.WithPageSize(10))
	if err != nil {
		return output + "Invalid page"
	}

	// Get current page number for back links
	currentPage := (pages.Offset() / pages.PageSize()) + 1

	for _, block := range blockStore.List((pages.Offset()/pages.PageSize())+1, pages.PageSize()) {
		blockID := block["id"]
		output += "### [" + escapeMarkdown(blockID+" - "+block["name"]) + "](./block:block?id=" + url.QueryEscape(blockID) + "&page=" + strconv.Itoa(currentPage) + ")\n\n"
		output += "* **Type**: " + escapeMarkdown(block["blockType"]) + "\n"
		output += "* **Max Supply**: " + escapeMarkdown(block["maxSupply"]) + "\n"
		output += "* **Mint Price**: " + escapeMarkdown(block["mintPrice"]) + " ugnot\n"
		output += "\n---\n\n"
	}

	if pages.HasPages() {
		output += pager.Picker(pages)
	}

	return output
}

func renderBlock(blockID string, page string) string {
	output := "# Block Detail\n\n"
	if page != "" {
		output += "[← Back to List](./block:blocks?page=" + url.QueryEscape(page) + ") | [View on Explorer](" + admin.GetExplorerURL() + "/m/explorer/block?id=" + url.QueryEscape(blockID) + ")\n\n"
	} else {
		output += "[← Home](./block:) | [View on Explorer](" + admin.GetExplorerURL() + "/m/explorer/block?id=" + url.QueryEscape(blockID) + ")\n\n"
	}

	bid, ok := parseBlockID(blockID)
	if !ok {
		return output + "Invalid block ID"
	}
	properties, found := blockStore.Get(bid)
	if !found {
		return output + "Block not found"
	}

	textureURL := properties["textureURL"]
	previewURL := properties["previewURL"]

	output += "## " + escapeMarkdown(properties["name"]) + "\n\n"

	output += `## Images
<gno-columns>
### Texture

|||

### Preview
</gno-columns>
<gno-columns>
`
	output += renderMarkdownImage("TextureURL", textureURL, "") + "\n\n|||\n\n" + renderMarkdownImage("PreviewURL", previewURL, "192") + "\n"
	output += "</gno-columns>\n\n"

	output += "## Properties\n\n"

	for key, value := range properties {
		output += renderBlockProperty(key, value)
	}

	return output
}

func renderInventory(owner string) string {
	output := "# Inventory of " + escapeMarkdown(owner) + "\n\n"
	output += "[← Home](./block:)\n\n"

	if owner == "" {
		return output + "Owner address is required"
	}

	inventory := GetInventory(address(owner))

	if len(inventory) == 0 {
		output += "*No blocks found for this owner.*\n"
		return output
	}

	output += "**Total Block Types**: " + strconv.Itoa(len(inventory)) + "\n\n"
	output += "---\n\n"

	for _, item := range inventory {
		blockID := item["id"]
		balance := item["balance"]

		// Get block info
		bid, ok := parseBlockID(blockID)
		block, found := blockStore.Get(bid)

		if ok && found {
			output += "### [" + escapeMarkdown(blockID+" - "+block["name"]) + "](./block:block?id=" + url.QueryEscape(blockID) + ")\n\n"
			output += "* **Balance**: " + escapeMarkdown(balance) + "\n"
			output += "* **Type**: " + escapeMarkdown(block["blockType"]) + "\n"
		} else {
			output += "### " + escapeMarkdown(blockID) + "\n\n"
			output += "* **Balance**: " + escapeMarkdown(balance) + "\n"
		}
		output += "\n---\n\n"
	}

	return output
}

func renderGRC1155(blockID string, owner string) string {
	output := "# GRC1155 Balance\n\n"
	output += "[← Home](./block:)\n\n"

	if blockID == "" || owner == "" {
		return output + "Block ID and owner address are required"
	}

	balance, found := balanceOfSafe(address(owner), grc1155.TokenID(blockID))
	if !found {
		return output + "Balance unavailable"
	}

	output += "* **Block ID**: " + escapeMarkdown(blockID) + "\n"
	output += "* **Owner**: " + escapeMarkdown(owner) + " [[View on Explorer](" + admin.GetExplorerURL() + "/m/explorer/player?address=" + url.QueryEscape(owner) + ")]\n"
	output += "* **Balance**: " + strconv.FormatInt(balance, 10) + "\n\n"

	return output
}

func uint32String(value uint32) string {
	return strconv.FormatUint(uint64(value), 10)
}

func formatBPSPercent(value uint32) string {
	return uint32String(value/100) + "." + pad2(value%100) + "%"
}

func formatBPSPercentInt(value int) string {
	return strconv.Itoa(value/100) + "." + pad2Int(value%100) + "%"
}

func pad2(value uint32) string {
	if value < 10 {
		return "0" + uint32String(value)
	}
	return uint32String(value)
}

func pad2Int(value int) string {
	if value < 10 {
		return "0" + strconv.Itoa(value)
	}
	return strconv.Itoa(value)
}

func renderBlockProperty(key, value string) string {
	escapedKey := escapeMarkdown(key)
	escapedValue := escapeMarkdown(value)
	if key == "mintPrice" || key == "usePrice" {
		return "* **" + escapedKey + "**: " + escapedValue + " ugnot\n"
	}
	if key == "installerBps" {
		bps, ok := parseBlockID(value)
		if ok {
			return "* **" + escapedKey + "**: " + escapedValue + " (" + formatBPSPercent(bps) + ")\n"
		}
		return "* **" + escapedKey + "**: " + escapedValue + "\n"
	}
	if key == "creator" {
		return "* **" + escapedKey + "**: " + escapedValue + " [[View on Explorer](" + admin.GetExplorerURL() + "/m/explorer/player?address=" + url.QueryEscape(value) + ")]\n"
	}
	if key == "textureURL" || key == "previewURL" {
		if isSafeRenderURL(value) {
			return "* **" + escapedKey + "**: [" + escapedValue + "](" + value + ")\n"
		}
		return "* **" + escapedKey + "**: " + escapedValue + "\n"
	}
	return "* **" + escapedKey + "**: " + escapedValue + "\n"
}

func renderMarkdownImage(label, value, size string) string {
	if isSafeRenderURL(value) {
		if size != "" {
			return "![" + label + "](" + value + " " + size + ")"
		}
		return "![" + label + "](" + value + ")"
	}
	return "*" + label + "*: " + escapeMarkdown(value)
}

func isSafeRenderURL(value string) bool {
	if !(strings.HasPrefix(value, "https://") || strings.HasPrefix(value, "http://")) {
		return false
	}
	for i := 0; i < len(value); i++ {
		switch value[i] {
		case ' ', '\t', '\n', '\r', '(', ')', '[', ']', '<', '>', '\\':
			return false
		}
		if value[i] < 0x20 || value[i] == 0x7f {
			return false
		}
	}
	return true
}

func escapeMarkdown(s string) string {
	s = strings.ReplaceAll(s, "\\", "\\\\")
	s = strings.ReplaceAll(s, "\n", "\\n")
	s = strings.ReplaceAll(s, "`", "\\`")
	s = strings.ReplaceAll(s, "*", "\\*")
	s = strings.ReplaceAll(s, "_", "\\_")
	s = strings.ReplaceAll(s, "{", "\\{")
	s = strings.ReplaceAll(s, "}", "\\}")
	s = strings.ReplaceAll(s, "[", "\\[")
	s = strings.ReplaceAll(s, "]", "\\]")
	s = strings.ReplaceAll(s, "(", "\\(")
	s = strings.ReplaceAll(s, ")", "\\)")
	s = strings.ReplaceAll(s, "#", "\\#")
	s = strings.ReplaceAll(s, "+", "\\+")
	s = strings.ReplaceAll(s, "-", "\\-")
	s = strings.ReplaceAll(s, ".", "\\.")
	s = strings.ReplaceAll(s, "!", "\\!")
	s = strings.ReplaceAll(s, "|", "\\|")
	s = strings.ReplaceAll(s, ">", "\\>")
	return s
}
