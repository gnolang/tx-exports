package blueprint

import (
	"net/url"
	"strconv"
	"strings"
)

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
	case "blueprint":
		idStr := query.Get("id")
		if idStr == "" {
			return renderError("Blueprint ID required")
		}
		return renderBlueprint(idStr)
	case "blueprints":
		owner := query.Get("owner")
		if owner != "" {
			return renderBlueprintsByOwner(owner)
		}
		biome := query.Get("biome")
		if biome != "" {
			return renderBlueprintsByBiome(biome)
		}
		return renderBlueprintsList()
	default:
		return renderError("Not found")
	}
}

func renderHome() string {
	output := "# Blueprints\n\n"
	output += "* **Creation Cost**: " + strconv.FormatInt(creationCost, 10) + " ugnot\n"
	output += "* **List Limit**: " + strconv.Itoa(listLimit) + "\n"
	output += "* **Batch Limit**: " + strconv.Itoa(batchLimit) + "\n"
	output += "* **Total Blueprints**: " + strconv.Itoa(blueprintStore.Total()) + "\n\n"
	output += "* [Browse All Blueprints](./blueprint:blueprints)\n"
	return output
}

func renderBlueprint(idStr string) string {
	idInt, err := strconv.Atoi(idStr)
	if err != nil || idInt < 1 {
		return renderError("Invalid blueprint ID")
	}
	blueprintID := uint32(idInt)
	blueprint, found := blueprintStore.Get(blueprintID)
	if !found {
		return renderError("Blueprint not found")
	}

	output := "# " + escapeMarkdown(blueprint["name"]) + "\n\n"
	output += "* **ID**: " + escapeMarkdown(blueprint["id"]) + "\n"
	output += "* **Owner**: " + escapeMarkdown(blueprint["owner"]) + "\n"
	output += "* **Biome**: " + escapeMarkdown(blueprint["biome"]) + "\n"
	output += "* **Chunk Verifier Count**: " + strconv.Itoa(verifierStore.Size(blueprintID)) + "\n"
	if description := blueprint["description"]; description != "" {
		output += "\n" + escapeMarkdown(description) + "\n"
	}
	return output
}

func renderBlueprintsList() string {
	totalSize := blueprintStore.Total()
	output := "# All Blueprints\n\n"
	if totalSize == 0 {
		output += "*No blueprints created yet.*\n"
		return output
	}

	ids := blueprintStore.ListIDs(1, 20)
	for _, blueprint := range blueprintStore.ListByIDs(ids...) {
		output += renderBlueprintItem(blueprint)
	}
	return output
}

func renderBlueprintsByOwner(owner string) string {
	ownerAddr := address(owner)
	if !ownerAddr.IsValid() {
		return renderError("Invalid owner address")
	}

	output := "# Blueprints by " + escapeMarkdown(ownerAddr.String()) + "\n\n"
	ids := blueprintStore.ListIDsByOwner(ownerAddr, 1, 20)
	if len(ids) == 0 {
		output += "*No blueprints found for this owner.*\n"
		return output
	}

	for _, blueprintID := range ids {
		if blueprint, found := blueprintStore.Get(blueprintID); found {
			output += renderBlueprintItem(blueprint)
		}
	}
	return output
}

func renderBlueprintsByBiome(biomeName string) string {
	assertBiomeName(biomeName)
	assertBiomeExists(biomeName)

	output := "# Blueprints in " + escapeMarkdown(biomeName) + "\n\n"
	ids := blueprintStore.ListIDsByBiome(biomeName, 1, 20)
	if len(ids) == 0 {
		output += "*No blueprints found for this biome.*\n"
		return output
	}

	for _, blueprintID := range ids {
		if blueprint, found := blueprintStore.Get(blueprintID); found {
			output += renderBlueprintItem(blueprint)
		}
	}
	return output
}

func renderBlueprintItem(blueprint map[string]string) string {
	output := "## [" + escapeMarkdown(blueprint["name"]) + "](./blueprint:blueprint?id=" + url.QueryEscape(blueprint["id"]) + ")\n\n"
	output += "* **Owner**: " + escapeMarkdown(blueprint["owner"]) + "\n"
	output += "* **Biome**: " + escapeMarkdown(blueprint["biome"]) + "\n\n"
	return output
}

func renderError(message string) string {
	return "# Error\n\n" + escapeMarkdown(message) + "\n"
}

func escapeMarkdown(input string) string {
	replacer := strings.NewReplacer(
		"\\", "\\\\",
		"*", "\\*",
		"_", "\\_",
		"[", "\\[",
		"]", "\\]",
		"(", "\\(",
		")", "\\)",
		"#", "\\#",
	)
	return replacer.Replace(input)
}
