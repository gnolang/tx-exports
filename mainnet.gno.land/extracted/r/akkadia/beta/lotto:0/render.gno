package lotto

import (
	"net/url"
	"strconv"
)

func Render(path string) string {
	output := `# AKKADIA Lotto

Look up owners and their quantities for a number.

<gno-form path="number">
  <gno-input name="number" placeholder="Enter a number" />
</gno-form>

`
	u, err := url.Parse(path)
	if err != nil {
		return output + "Invalid URL\n"
	}
	query, err := url.ParseQuery(u.RawQuery)
	if err != nil {
		return output + "Invalid query\n"
	}
	switch u.Path {
	case "":
		return output
	case "number":
		raw := query.Get("number")
		if raw == "" {
			return output + "Number is required\n"
		}
		number, err := strconv.ParseUint(raw, 10, 64)
		if err != nil {
			return output + "Invalid number\n"
		}
		afterOwner := query.Get("afterOwner")
		if afterOwner != "" && !address(afterOwner).IsValid() {
			return output + "Invalid cursor address\n"
		}
		numberStr := strconv.FormatUint(number, 10)
		page := ListOwnersByNumber(number, afterOwner, 20)
		output += "## Number " + numberStr + "\n\n"
		output += "[Home](./lotto:)\n\n"
		if afterOwner != "" {
			output += "[First page](./lotto:number?number=" + numberStr + ")\n\n"
		}
		if len(page) == 0 {
			return output + "No owners on this page.\n"
		}
		output += "| Owner | Count |\n| --- | ---: |\n"
		for _, item := range page {
			// Owners are validated addresses and counts are formatted integers.
			output += "| " + item["owner"] + " | " + item["count"] + " |\n"
		}
		if page[0]["nextOwner"] != "" {
			output += "\n[Next](./lotto:number?number=" + numberStr + "&afterOwner=" + url.QueryEscape(page[0]["nextOwner"]) + ")\n"
		}
		return output
	default:
		return output + "Page not found\n"
	}
}
