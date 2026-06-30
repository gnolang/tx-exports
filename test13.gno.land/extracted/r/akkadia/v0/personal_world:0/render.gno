package personal_world

import (
	"net/url"
	"strconv"
	"strings"

	"gno.land/p/jeronimoalbi/pager"
	"gno.land/r/akkadia/v0/admin"
)

// Render handles RESTful routing and returns Markdown responses
func Render(iUrl string) string {
	assertMigrationStateAvailable()
	u, err := url.Parse(iUrl)
	if err != nil {
		return "404\n"
	}

	query := u.Query()

	switch u.Path {
	case "":
		return renderHome()
	case "world":
		idStr := query.Get("id")
		if idStr == "" {
			return renderError("World ID required")
		}
		return renderWorld(iUrl, idStr)
	case "worlds":
		owner := query.Get("owner")
		if owner != "" {
			return renderWorldsByOwner(iUrl, owner)
		}
		return renderWorldsList(iUrl)
	case "biomes":
		return renderBiomes()
	case "sizes":
		return renderSizes()
	default:
		return renderError("Not found")
	}
}

// renderHome renders the home page
func renderHome() string {
	output := `# Personal World

Welcome to the Personal World system on Akkadia.

## What is Personal World?

Personal World is a decentralized world creation and management system where users can:

* Create and customize their own worlds
* Manage world editors and permissions
* Expand world sizes dynamically
* Set custom world types and properties

## Getting Started

1. **Create Your First World**: World creation costs the selected biome price.
2. **Customize**: Set name, slug and visibility
3. **Manage**: Add editors, expand size, update properties
4. **Explore**: Browse all worlds and discover unique creations

## Config

`
	metadata := worldConfigStore
	worlds := worldStore
	output += "* **Default Biome**: " + metadata.DefaultBiome() + "\n"
	output += "* **Fee Collector BPS**: " + strconv.Itoa(feeCollectorBPS) + " (" + strconv.Itoa(feeCollectorBPS/100) + "." + strconv.Itoa(feeCollectorBPS%100) + "%)\n"
	output += "* **List Limit**: " + strconv.Itoa(listLimit) + "\n"
	output += "* **Batch Limit**: " + strconv.Itoa(batchLimit) + "\n"

	output += `
## Stats

`
	output += "* **Total Worlds**: " + strconv.Itoa(worlds.Total()) + "\n"

	output += `
## Quick Links

* [Browse All Worlds](./personal_world:worlds)
* [View Biomes](./personal_world:biomes)
* [View Sizes](./personal_world:sizes)

## Search by Owner

<gno-form path="worlds">
  <gno-input name="owner" placeholder="Enter owner address" />
</gno-form>
`

	return output
}

// renderBiomes renders the biomes page
func renderBiomes() string {
	output := `# Biomes

[← Home](./personal_world:)

The system supports multiple biomes with different creation costs.

## How Pricing Works

* **cost**: The base cost to create a world with this biome
* **priceMultiplierBPS**: Multiplier applied to world expansion costs, where 10000 means 1x
  * Example: If expansion base cost is 1000 ugnot and priceMultiplierBPS is 15000, actual cost = 1500 ugnot

---

`
	metadata := worldConfigStore
	defaultBiome := metadata.DefaultBiome()
	for _, biome := range metadata.ListBiomeInfos() {
		output += "### " + escapeMarkdown(biome["name"]) + "\n\n"

		for k, v := range biome {
			if k == "name" {
				if v == defaultBiome {
					output += "* **" + escapeMarkdown(k) + "**: " + escapeMarkdown(v) + " (default)\n"
				} else {
					output += "* **" + escapeMarkdown(k) + "**: " + escapeMarkdown(v) + "\n"
				}
			} else if k == "cost" {
				output += "* **" + escapeMarkdown(k) + "**: " + escapeMarkdown(v) + " ugnot\n"
			} else {
				output += "* **" + escapeMarkdown(k) + "**: " + escapeMarkdown(v) + "\n"
			}
		}
		output += "\n---\n\n"
	}

	return output
}

// renderSizes renders the sizes page
func renderSizes() string {
	output := `# World Sizes

[← Home](./personal_world:)

Worlds can be expanded to larger sizes. Each expansion has a base cost.

## How Expansion Works

* **size**: The world dimension (size x size blocks)
* **cost**: Base cost to expand to this size level
* Actual expansion cost = base cost × biome priceMultiplierBPS / 10000
* New worlds start at size level 0

---

`
	for _, size := range worldConfigStore.ListSizeInfos() {
		output += "### Level " + size["id"] + "\n\n"
		output += "* **Size**: " + escapeMarkdown(size["size"]) + " × " + escapeMarkdown(size["size"]) + " blocks\n"
		output += "* **Base Cost**: " + escapeMarkdown(size["cost"]) + " ugnot\n"
		output += "\n---\n\n"
	}

	return output
}

// renderWorldsList renders a list of all worlds with pagination
func renderWorldsList(iUrl string) string {
	output := `# All Worlds

[← Home](./personal_world:)

`

	worlds := worldStore
	totalSize := worlds.Total()
	if totalSize == 0 {
		output += "*No worlds created yet.*\n"
		return output
	}

	pages, err := pager.New(iUrl, totalSize, pager.WithPageSize(10))
	if err != nil {
		return renderError("Invalid page")
	}

	// Get current page number for back links
	currentPage := (pages.Offset() / pages.PageSize()) + 1

	for _, worldID := range worlds.ListIDs(currentPage, pages.PageSize()) {
		if world, found := worlds.Get(worldID); found {
			output += renderWorldItem(world, currentPage)
		}
	}

	if pages.HasPages() {
		output += pager.Picker(pages)
	}

	return output
}

// renderWorldsByOwner renders worlds owned by a specific address with pagination
func renderWorldsByOwner(iUrl string, owner string) string {
	u, _ := url.Parse(iUrl)
	page := u.Query().Get("page")
	ownerAddr := address(owner)
	if !ownerAddr.IsValid() {
		return renderError("Invalid owner address")
	}
	owner = ownerAddr.String()

	output := "# Personal Worlds by " + escapeMarkdown(owner) + "\n\n"
	if page != "" {
		output += "[← Back to List](./personal_world:worlds?page=" + url.QueryEscape(page) + ")\n\n"
	} else {
		output += "[← Home](./personal_world:)\n\n"
	}

	totalOwnerWorlds := GetWorldSizeByOwner(ownerAddr)
	if totalOwnerWorlds == 0 {
		output += "*No worlds found for this owner.*\n"
		return output
	}

	pages, err := pager.New(iUrl, totalOwnerWorlds, pager.WithPageSize(10))
	if err != nil {
		return renderError("Invalid page")
	}

	currentPage := (pages.Offset() / pages.PageSize()) + 1
	ownerWorldIDs := worldStore.ListIDsByOwner(ownerAddr, currentPage, pages.PageSize())

	for _, worldID := range ownerWorldIDs {
		if world, found := worldStore.Get(worldID); found {
			output += renderWorldItem(world, 0)
		}
	}

	if pages.HasPages() {
		output += pager.Picker(pages)
	}

	return output
}

// renderWorldItem renders a single world item
func renderWorldItem(world map[string]string, page int) string {
	explorerURL := admin.GetExplorerURL()
	worldID := world["id"]
	worldName := escapeMarkdown(world["name"])
	worldOwner := escapeMarkdown(world["owner"])
	worldOwnerParam := url.QueryEscape(world["owner"])
	worldSlugParam := url.QueryEscape(world["slug"])
	output := ""
	output += "* **ID**: " + escapeMarkdown(worldID) + "\n"
	if page > 0 {
		pageStr := strconv.Itoa(page)
		output += "* **Name**: [" + worldName + "](./personal_world:world?id=" + url.QueryEscape(worldID) + "&page=" + pageStr + ")\n"
		output += "* **Owner**: " + worldOwner + " [[View on Explorer](" + explorerURL + "/m/explorer/player?address=" + worldOwnerParam + ")] [[Worlds by Owner](./personal_world:worlds?owner=" + worldOwnerParam + "&page=" + pageStr + ")]\n"
	} else {
		output += "* **Name**: [" + worldName + "](./personal_world:world?id=" + url.QueryEscape(worldID) + ")\n"
		output += "* **Owner**: " + worldOwner + " [[View on Explorer](" + explorerURL + "/m/explorer/player?address=" + worldOwnerParam + ")] [[Worlds by Owner](./personal_world:worlds?owner=" + worldOwnerParam + ")]\n"
	}
	output += "* **Biome**: " + escapeMarkdown(world["biome"]) + "\n"
	output += "* **Size**: " + escapeMarkdown(world["size"]) + "\n"
	output += "* **Slug**: `" + escapeCodeSpan(world["slug"]) + "` [[View on Explorer](" + explorerURL + "/m/explorer/community-realm?slug=" + worldSlugParam + ")]\n"
	output += "\n---\n\n"
	return output
}

// renderWorld renders a single world detail page
func renderWorld(iUrl string, idStr string) string {
	worldID64, err := strconv.ParseUint(idStr, 10, 32)
	if err != nil {
		return renderError("Invalid world ID: " + idStr)
	}
	worldID := uint32(worldID64)

	world, found := worldStore.Get(worldID)
	if !found {
		return renderError("World not found: " + idStr)
	}

	u, _ := url.Parse(iUrl)
	pageParam := u.Query().Get("page")

	backLink := "./personal_world:worlds"
	if pageParam != "" {
		backLink += "?page=" + pageParam
	}

	explorerURL := admin.GetExplorerURL()

	output := "# World " + escapeMarkdown(world["name"]) + " (#" + escapeMarkdown(world["id"]) + ")\n\n"
	output += "[← All Worlds](" + backLink + ")\n"
	output += "[[View on Explorer](" + explorerURL + "/m/explorer/community-realm?slug=" + url.QueryEscape(world["slug"]) + ")]\n\n"

	output += "## Info\n\n"
	output += "* **ID**: " + escapeMarkdown(world["id"]) + "\n"
	output += "* **Name**: " + escapeMarkdown(world["name"]) + "\n"
	output += "* **Slug**: `" + escapeCodeSpan(world["slug"]) + "`\n"
	output += "* **Owner**: " + escapeMarkdown(world["owner"]) + " [[View on Explorer](" + explorerURL + "/m/explorer/player?address=" + url.QueryEscape(world["owner"]) + ")] [[Worlds by Owner](./personal_world:worlds?owner=" + url.QueryEscape(world["owner"]) + ")]\n"
	output += "* **Biome**: " + escapeMarkdown(world["biome"]) + "\n"
	output += "* **Size**: " + escapeMarkdown(world["size"]) + " (Level " + escapeMarkdown(world["sizeId"]) + ")\n"
	output += "* **Seed**: " + escapeMarkdown(world["seed"]) + "\n"
	output += "* **Visible**: " + escapeMarkdown(world["isVisible"]) + "\n"
	output += "* **Total Paid**: " + escapeMarkdown(world["totalPaid"]) + " ugnot\n"
	output += "* **Created**: block #" + escapeMarkdown(world["createdAt"]) + "\n"
	output += "* **Updated**: block #" + escapeMarkdown(world["updatedAt"]) + "\n"

	output += "\n## Roles\n\n"
	worldKey := formatWorldID(worldID)
	roles := personalWorldAuthzRBAC.ListRoles(1, listLimit)
	hasRoles := false
	for _, role := range roles {
		users := personalWorldAuthzRBAC.ListRoleUsers(worldKey, role.Name, 1, listLimit)
		if len(users) != 0 {
			hasRoles = true
			break
		}
	}
	if hasRoles {
		output += "| Address | Roles |\n"
		output += "|---------|-------|\n"
		for _, role := range roles {
			users := personalWorldAuthzRBAC.ListRoleUsers(worldKey, role.Name, 1, listLimit)
			for _, user := range users {
				output += "| " + escapeMarkdown(user.String()) + " | " + escapeMarkdown(role.Name) + " |\n"
			}
		}
	} else {
		output += "*No roles assigned.*\n"
	}

	return output
}

// renderError renders an error page
func renderError(message string) string {
	output := "# Error\n\n"
	output += "> " + escapeMarkdown(message) + "\n\n"
	output += "[← Back to Home](./personal_world:)\n"
	return output
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

func escapeCodeSpan(s string) string {
	return strings.ReplaceAll(s, "`", "\\`")
}
