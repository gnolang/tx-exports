package definition

import (
	"html"
	"net/url"
	"strconv"
	"strings"
	"unicode"
)

func Render(path string) string {
	u, err := url.Parse(path)
	if err != nil {
		return renderError("Invalid URL")
	}
	query, err := url.ParseQuery(u.RawQuery)
	if err != nil {
		return renderError("Invalid query")
	}
	page := 1
	if raw := query.Get("page"); raw != "" {
		page, err = strconv.Atoi(raw)
		if err != nil || page < 1 {
			return renderError("Invalid page")
		}
	}
	key := query.Get("key")
	output := "# AKKADIA Definition\n\n[All items](./definition:)\n\n" + renderSearchForm(key)
	switch u.Path {
	case "", "list":
		total := GetKeyCount()
		output += "## Items (" + strconv.Itoa(total) + ")\n\n"
		keys := ListKeys(page, 20)
		if len(keys) == 0 {
			output += "No entries on this page.\n"
		}
		for _, key := range keys {
			label := key
			if itemKey, found := GetField(key, "key")["value"]; found && itemKey != "" {
				label += " — " + itemKey
			}
			output += "* [" + renderLabel(label) + "](./definition:search?key=" + url.QueryEscape(key) + "&page=" + strconv.Itoa(page) + ")\n"
		}
		pages := 1
		if total > 0 {
			pages = (total-1)/20 + 1
		}
		output += "\nPage " + strconv.Itoa(page) + " / " + strconv.Itoa(pages) + "\n"
		return output + renderPages("./definition:list?", page, total)
	case "search":
		if strings.TrimSpace(key) == "" {
			return output + "Key is required\n"
		}
		fields, found := getFields(key)
		if !found {
			return output + "Entry not found\n"
		}
		output += "[Back to list](./definition:list?page=" + strconv.Itoa(page) + ")\n\n"
		output += "## " + renderLabel(key) + "\n\n"
		for _, field := range fields {
			output += "### " + renderLabel(field.Key) + "\n\n"
			link, err := url.Parse(field.Value)
			isLink := err == nil && (link.Scheme == "http" || link.Scheme == "https") && link.Hostname() != "" && link.Opaque == ""
			for _, r := range field.Value {
				if unicode.IsSpace(r) || unicode.IsControl(r) {
					isLink = false
				}
			}
			if isLink {
				// Angle-delimited Markdown destinations retain parentheses and ampersands.
				target := strings.ReplaceAll(strings.ReplaceAll(link.String(), "<", "%3C"), ">", "%3E")
				output += "[" + renderLabel(field.Value) + "](<" + target + ">)\n\n"
			} else {
				// A fence longer than any user fence keeps HTML and Markdown literal.
				longest, run := 2, 0
				for _, r := range field.Value {
					if r == '`' {
						run++
						if run > longest {
							longest = run
						}
					} else {
						run = 0
					}
				}
				fence := strings.Repeat("`", longest+1)
				output += fence + "\n" + field.Value + "\n" + fence + "\n\n"
			}
		}
		return output
	default:
		return renderError("Page not found")
	}
}

func renderLabel(value string) string {
	// Gnoweb's TOC unescapes Markdown punctuation but leaves HTML entities literal.
	var output strings.Builder
	for _, r := range value {
		if unicode.IsControl(r) {
			output.WriteString(" ")
			continue
		}
		if (r >= '!' && r <= '/') || (r >= ':' && r <= '@') || (r >= '[' && r <= '`') || (r >= '{' && r <= '~') {
			output.WriteString("\\")
		}
		output.WriteRune(r)
	}
	return output.String()
}

func renderPages(base string, page, total int) string {
	output := "\n"
	if page > 1 {
		output += "[Previous](" + base + "page=" + strconv.Itoa(page-1) + ") "
	}
	if total > 0 && page <= (total-1)/20 {
		output += "[Next](" + base + "page=" + strconv.Itoa(page+1) + ")"
	}
	return output + "\n"
}

func renderError(message string) string {
	return "# Definition\n\n" + message + "\n\n[All items](./definition:)\n\n" + renderSearchForm("")
}

func renderSearchForm(key string) string {
	return "<gno-form path=\"search\">\n  <gno-input name=\"key\" value=\"" + html.EscapeString(key) + "\" placeholder=\"Item ID (e.g. 1101000)\" />\n</gno-form>\n\n"
}
