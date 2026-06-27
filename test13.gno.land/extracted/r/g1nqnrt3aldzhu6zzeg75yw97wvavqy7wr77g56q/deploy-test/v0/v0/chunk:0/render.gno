package chunk

import (
	"net/url"
	"strconv"
	"strings"

	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/grc721"
	"gno.land/p/jeronimoalbi/pager"
	"gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/admin"
)

const renderChunkPageSize = 10

// Render
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
	case path == "chunk":
		id := query.Get("id")
		if id == "" {
			return renderChunkForm()
		}
		return renderChunk(iUrl, id)
	case path == "worlds":
		return renderWorldsList(iUrl)
	case strings.HasPrefix(path, "worlds/") && strings.HasSuffix(path, "/chunks"):
		worldIDStr := strings.TrimPrefix(path, "worlds/")
		worldIDStr = strings.TrimSuffix(worldIDStr, "/chunks")
		worldID, err := strconv.ParseUint(worldIDStr, 10, 32)
		if err != nil {
			return "404\n"
		}
		owner := query.Get("owner")
		if owner != "" {
			return renderChunksByOwner(iUrl, uint32(worldID), owner)
		}
		return renderChunksByWorld(iUrl, uint32(worldID))
	case strings.HasPrefix(path, "worlds/"):
		worldIDStr := strings.TrimPrefix(path, "worlds/")
		worldID, err := strconv.ParseUint(worldIDStr, 10, 32)
		if err != nil {
			return "404\n"
		}
		return renderWorld(iUrl, uint32(worldID))
	default:
		return "404\n"
	}
}

func renderHome() string {
	output := `# Chunk

Welcome to the Chunk management system on Akkadia.

## What is Chunk?

Chunk is an NFT-based land ownership system where each chunk represents a unique piece of land in the game world:

* **GRC721 NFT**: Each chunk is a unique token with ownership and transferability
* **World-based**: Chunks belong to specific worlds with coordinates (x, y)
* **Metadata Storage**: Each chunk stores custom metadata for game state
* **Role-based Access**: Permissions control who can mint, burn, and modify chunks

## How Chunks Work

1. **World Creation**: Admins create worlds with biome, name, slug, and seed
2. **Chunk Minting**: Authorized users mint chunks at specific coordinates
3. **Metadata Management**: Chunk owners can update metadata for game state
4. **Ownership Transfer**: Chunks can be transferred between users as NFTs

## Config

`
	output += "* **List Limit**: " + strconv.Itoa(listLimit) + "\n"
	output += "* **Batch Limit**: " + strconv.Itoa(batchLimit) + "\n"

	output += `
## Stats

`
	output += "* **Total Chunks**: " + strconv.FormatInt(TokenCount(), 10) + "\n"
	output += "* **Total Worlds**: " + strconv.Itoa(GetTotalWorldSize()) + "\n"

	output += `
## Quick Links

* [Browse Worlds](./chunk:worlds)
* [Search Chunk by ID](./chunk:chunk)
`

	return output
}

func renderChunkForm() string {
	return `# View Chunk

[← Home](./chunk:)

<gno-form path="chunk">
  <gno-input name="id" placeholder="Enter chunk ID (e.g., 1:0_0)" />
</gno-form>
`
}

func renderChunk(iUrl string, id string) string {
	if !isValidRenderChunkID(id) {
		if worldID, ok := parseWorldIDLookup(id); ok {
			if _, found := worldStore.Get(worldID); found {
				return renderWorldIDLookup(id)
			}
		}
		return "# Chunk Not Found\n\n[← Home](./chunk:)\n\nChunk `" + id + "` does not exist.\n"
	}

	tokenID := grc721.TokenID(id)
	meta := GetChunkMetadata(string(tokenID))
	if meta == nil {
		return "# Chunk Not Found\n\n[← Home](./chunk:)\n\nChunk `" + id + "` does not exist.\n"
	}

	u, _ := url.Parse(iUrl)
	query := u.Query()
	pageParam := query.Get("page")
	ownerParam := query.Get("owner")

	worldIDStr := meta["worldId"]

	output := "# Chunk " + id + "\n\n"
	output += "[[View on Explorer](" + admin.GetExplorerURL() + "/m/explorer/chunk?id=" + id + ")]\n\n"

	backLink := "./chunk:worlds/" + worldIDStr + "/chunks"
	if ownerParam != "" {
		backLink += "?owner=" + ownerParam
		if pageParam != "" {
			backLink += "&page=" + pageParam
		}
	} else if pageParam != "" {
		backLink += "?page=" + pageParam
	}
	output += "[← Back to World " + worldIDStr + " Chunks](" + backLink + ")\n\n"

	owner, found := nftStore.OwnerOfSafe(tokenID)
	if found {
		ownerStr := owner.String()
		output += "* **Owner**: [" + ownerStr + "](./chunk:worlds/" + worldIDStr + "/chunks?owner=" + ownerStr + ") [[View on Explorer](" + admin.GetExplorerURL() + "/m/explorer/player?address=" + ownerStr + ")]\n"
	} else {
		output += "* **Owner**: unavailable\n"
	}
	output += "* **World**: [" + worldIDStr + "](./chunk:worlds/" + worldIDStr + ")\n"
	output += "* **Coordinates**: (" + meta["x"] + ", " + meta["y"] + ")\n"
	output += "* **World Type**: " + meta["worldType"] + "\n"
	output += "* **Hash**: " + meta["hash"] + "\n"

	return output
}

func isValidRenderChunkID(id string) bool {
	parts := strings.SplitN(id, ":", 2)
	if len(parts) != 2 {
		return false
	}

	if _, err := strconv.ParseUint(parts[0], 10, 32); err != nil {
		return false
	}

	coords := strings.SplitN(parts[1], "_", 2)
	if len(coords) != 2 {
		return false
	}

	if _, err := strconv.Atoi(coords[0]); err != nil {
		return false
	}
	if _, err := strconv.Atoi(coords[1]); err != nil {
		return false
	}
	return true
}

func parseWorldIDLookup(id string) (uint32, bool) {
	worldID, err := strconv.ParseUint(id, 10, 32)
	if err != nil {
		return 0, false
	}
	return uint32(worldID), true
}

func renderWorldIDLookup(id string) string {
	output := "# World ID Entered\n\n"
	output += "[← Home](./chunk:)\n\n"
	output += "`" + id + "` is a world ID, not a chunk ID. Chunk IDs use `worldID:x_y` format.\n\n"
	output += "* [View World " + id + "](./chunk:worlds/" + id + ")\n"
	output += "* [View World " + id + " Chunks](./chunk:worlds/" + id + "/chunks)\n"
	return output
}

// renderWorld renders a single system world detail page
func renderWorld(iUrl string, worldID uint32) string {
	world, found := worldStore.Get(worldID)
	if !found {
		return "# World Not Found\n\n[← All Worlds](../chunk:worlds)\n\nWorld `" + formatWorldID(worldID) + "` does not exist.\n"
	}

	worldIDStr := world["id"]
	output := "# World " + world["name"] + " (#" + worldIDStr + ")\n\n"
	output += "[← All Worlds](../chunk:worlds)\n"
	output += "[[View on Explorer](" + admin.GetExplorerURL() + "/m/explorer/primary-realm?slug=" + world["slug"] + ")]\n\n"

	output += "## Info\n\n"
	output += "* **ID**: " + worldIDStr + "\n"
	output += "* **Name**: " + world["name"] + "\n"
	output += "* **Slug**: `" + world["slug"] + "` [[View on Explorer](" + admin.GetExplorerURL() + "/m/explorer/primary-realm?slug=" + world["slug"] + ")]\n"
	output += "* **Biome**: " + world["biome"] + "\n"
	output += "* **Seed**: " + world["seed"] + "\n"
	output += "* **Created**: block #" + world["createdAt"] + "\n"
	output += "* **Updated**: block #" + world["updatedAt"] + "\n"
	propCount := len(world) - 7
	if propCount > 0 {
		output += "* **Properties**: " + strconv.Itoa(propCount) + "\n"
	}

	chunkCount := GetChunkMetadataSizeByWorld(worldID)
	output += "\n## Chunks\n\n* **Total**: " + strconv.Itoa(chunkCount) + " [[View All Chunks](../chunk:worlds/" + worldIDStr + "/chunks)]\n"

	return output
}

// renderChunksByWorld renders chunks belonging to a specific world with pagination
func renderChunksByWorld(iUrl string, worldID uint32) string {
	worldIDStr := formatWorldID(worldID)
	output := "# Chunks in World " + worldIDStr + "\n\n"
	output += "[← World " + worldIDStr + "](../../chunk:worlds/" + worldIDStr + ")\n\n"

	chunkCount := GetChunkMetadataSizeByWorld(worldID)
	if chunkCount == 0 {
		output += "*No chunks found in this world.*\n"
		return output
	}

	output += "**Total Chunks**: " + strconv.Itoa(chunkCount) + "\n\n"

	u, err := url.Parse(iUrl)
	if err != nil {
		return output + "Invalid page"
	}
	page := 1
	pageStr := u.Query().Get("page")
	if pageStr != "" {
		parsedPage, err := strconv.Atoi(pageStr)
		if err != nil || parsedPage < 1 {
			return output + "Invalid page"
		}
		page = parsedPage
	}

	chunks := ListChunkMetadataByWorld(worldID, page, renderChunkPageSize)

	for _, chunk := range chunks {
		key := chunk["id"]
		chunkLink := "../../chunk:chunk?id=" + key + "&worldId=" + worldIDStr
		if page > 1 {
			chunkLink += "&page=" + strconv.Itoa(page)
		}
		output += "### [" + key + "](" + chunkLink + ") [[View on Explorer](" + admin.GetExplorerURL() + "/m/explorer/chunk?id=" + key + ")]\n\n"
		owner, found := nftStore.OwnerOfSafe(grc721.TokenID(key))
		if found {
			ownerStr := owner.String()
			output += "* **Owner**: " + ownerStr + " [[View on Explorer](" + admin.GetExplorerURL() + "/m/explorer/player?address=" + ownerStr + ")] [[Chunks by Owner](../../chunk:worlds/" + worldIDStr + "/chunks?owner=" + ownerStr + ")]\n"
		} else {
			output += "* **Owner**: unavailable\n"
		}
		for k, v := range chunk {
			output += "* **" + k + "**: " + v + "\n"
		}
		output += "\n---\n\n"
	}

	if len(chunks) > 0 {
		nav := []string{}
		if page > 1 {
			nav = append(nav, "[← Prev "+strconv.Itoa(renderChunkPageSize)+"](../../chunk:worlds/"+worldIDStr+"/chunks?page="+strconv.Itoa(page-1)+")")
		}
		nextPage := ListChunkMetadataByWorld(worldID, page+1, 1)
		if len(nextPage) > 0 {
			nav = append(nav, "[Next "+strconv.Itoa(renderChunkPageSize)+" →](../../chunk:worlds/"+worldIDStr+"/chunks?page="+strconv.Itoa(page+1)+")")
		}
		if len(nav) > 0 {
			output += strings.Join(nav, " | ") + "\n"
		}
	}

	return output
}

// renderChunksByOwner renders chunks owned by a specific address in a world
func renderChunksByOwner(iUrl string, worldID uint32, owner string) string {
	worldIDStr := formatWorldID(worldID)
	output := "# Chunks by " + owner + " in World " + worldIDStr + "\n\n"
	output += "[← World " + worldIDStr + " Chunks](../../chunk:worlds/" + worldIDStr + "/chunks)\n\n"

	ownerAddr := address(owner)
	totalCount := GetOwnerTokenSize(worldID, ownerAddr)

	if totalCount == 0 {
		output += "*No chunks found for this owner in this world.*\n"
		return output
	}

	output += "**Total Chunks**: " + strconv.Itoa(totalCount) + "\n\n"

	u, err := url.Parse(iUrl)
	if err != nil {
		return output + "Invalid page"
	}
	page := 1
	pageStr := u.Query().Get("page")
	if pageStr != "" {
		parsedPage, err := strconv.Atoi(pageStr)
		if err != nil || parsedPage < 1 {
			return output + "Invalid page"
		}
		page = parsedPage
	}

	chunkKeys := ListChunkKeysByOwner(worldID, ownerAddr, page, renderChunkPageSize)
	for _, key := range chunkKeys {
		meta := GetChunkMetadata(key)
		if meta == nil {
			continue
		}
		chunkLink := "../../chunk:chunk?id=" + key + "&worldId=" + worldIDStr + "&owner=" + owner
		if page > 1 {
			chunkLink += "&page=" + strconv.Itoa(page)
		}
		output += "### [" + key + "](" + chunkLink + ") [[View on Explorer](" + admin.GetExplorerURL() + "/m/explorer/chunk?id=" + key + ")]\n\n"
		for k, v := range meta {
			output += "* **" + k + "**: " + v + "\n"
		}
		output += "\n---\n\n"
	}

	if len(chunkKeys) > 0 {
		nav := []string{}
		if page > 1 {
			nav = append(nav, "[← Prev "+strconv.Itoa(renderChunkPageSize)+"](../../chunk:worlds/"+worldIDStr+"/chunks?owner="+owner+"&page="+strconv.Itoa(page-1)+")")
		}
		nextPage := ListChunkKeysByOwner(worldID, ownerAddr, page+1, 1)
		if len(nextPage) > 0 {
			nav = append(nav, "[Next "+strconv.Itoa(renderChunkPageSize)+" →](../../chunk:worlds/"+worldIDStr+"/chunks?owner="+owner+"&page="+strconv.Itoa(page+1)+")")
		}
		if len(nav) > 0 {
			output += strings.Join(nav, " | ") + "\n"
		}
	}

	return output
}

// renderWorldsList renders a list of all worlds with pagination
func renderWorldsList(iUrl string) string {
	output := `# All System Worlds

[← Home](./chunk:)

`
	if GetTotalWorldSize() == 0 {
		output += "*No worlds created yet.*\n"
		return output
	}

	pages, err := pager.New(iUrl, GetTotalWorldSize(), pager.WithPageSize(10))
	if err != nil {
		return output + "Invalid page"
	}

	worlds := worldStore.List((pages.Offset()/pages.PageSize())+1, pages.PageSize())
	for _, world := range worlds {
		worldIDStr := world["id"]
		worldID, _ := strconv.ParseUint(worldIDStr, 10, 32)
		chunkCount := GetChunkMetadataSizeByWorld(uint32(worldID))

		output += "* **ID**: " + worldIDStr + "\n"
		output += "* **Name**: [" + world["name"] + "](./chunk:worlds/" + worldIDStr + ")\n"
		output += "* **Biome**: " + world["biome"] + "\n"
		output += "* **Seed**: " + world["seed"] + "\n"
		output += "* **Slug**: `" + world["slug"] + "` [[View on Explorer](" + admin.GetExplorerURL() + "/m/explorer/primary-realm?slug=" + world["slug"] + ")]\n"
		output += "* **Chunks**: " + strconv.Itoa(chunkCount) + " [[View Chunks](./chunk:worlds/" + worldIDStr + "/chunks)]\n"
		output += "\n---\n\n"
	}

	if pages.HasPages() {
		output += pager.Picker(pages)
	}

	return output
}
