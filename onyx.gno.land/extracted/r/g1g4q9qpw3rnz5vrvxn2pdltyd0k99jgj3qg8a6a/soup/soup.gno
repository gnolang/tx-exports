// Realm soup: a read-only page for the soup package. No state, no transactions.
// Render is a query, so trying a sentence here is free and nothing is stored.
// Durumu yok; Render sorgudur, ucretsizdir, hicbir sey saklanmaz.
package soup

import (
	"strings"

	filter "gno.land/p/g1g4q9qpw3rnz5vrvxn2pdltyd0k99jgj3qg8a6a/soup"
	"gno.land/p/nt/ufmt/v0"
)

// Render paths:
//   ""             about + version
//   "check/<text>" result for <text>
func Render(path string) string {
	if strings.HasPrefix(path, "check/") {
		text := strings.TrimPrefix(path, "check/")
		toxic, secret, flavor, conf := filter.Check(text)
		out := "# soup check\n\n"
		safe := "no"
		if toxic == "" && secret == "" {
			safe = "yes"
		}
		out += "| | |\n|---|---|\n"
		out += "| toxic | " + dash(toxic) + " |\n"
		out += "| secret | " + dash(secret) + " |\n"
		out += "| flavor | " + dash(flavor) + " (" + ufmt.Sprintf("%d", conf) + " percent) |\n"
		out += "| safe | " + safe + " |\n"
		return out
	}
	return "# soup\n\n" +
		"A safety check for messages, before an app stores them: toxic words, leaked secrets, and flavor.\n\n" +
		"Package: `gno.land/p/g1g4q9qpw3rnz5vrvxn2pdltyd0k99jgj3qg8a6a/soup` version **" + filter.Version + "**\n\n" +
		"Try it: add `:check/your sentence` to this page's address. Nothing is stored.\n"
}

func dash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}
