// Realm soup: a read-only page for the soup package. No state, no transactions.
// Render is a query, so trying a sentence here is free and nothing is stored.
package soup

import (
	"net/url"
	"strings"

	filter "gno.land/p/g1g4q9qpw3rnz5vrvxn2pdltyd0k99jgj3qg8a6a/soup/v0"
	"gno.land/p/nt/ufmt/v0"
)

const (
	pkgPath  = "gno.land/p/g1g4q9qpw3rnz5vrvxn2pdltyd0k99jgj3qg8a6a/soup/v0"
	selfPath = "/r/g1g4q9qpw3rnz5vrvxn2pdltyd0k99jgj3qg8a6a/soup/v1"
	repo     = "https://github.com/jakalijey/soup"
	logo     = "data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAzNjAgMTIwIiB3aWR0aD0iMzYwIiBoZWlnaHQ9IjEyMCI+PHRleHQgeD0iMTYiIHk9Ijg2IiBmb250LWZhbWlseT0iR2VvcmdpYSwnVGltZXMgTmV3IFJvbWFuJyxzZXJpZiIgZm9udC1zaXplPSI4OCIgZm9udC13ZWlnaHQ9IjcwMCIgZmlsbD0iIzBGNzY2RSI+czwvdGV4dD48ZyB0cmFuc2Zvcm09InRyYW5zbGF0ZSgxMDMgNjIpIj48Y2lyY2xlIHI9IjI3IiBmaWxsPSJub25lIiBzdHJva2U9IiNEOTc3MDYiIHN0cm9rZS13aWR0aD0iMTAiLz48cGF0aCBkPSJNLTE0IDBoMjhNMC0xNHYyOCIgc3Ryb2tlPSIjMEQ5NDg4IiBzdHJva2Utd2lkdGg9IjUiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPjwvZz48dGV4dCB4PSIxMzYiIHk9Ijg2IiBmb250LWZhbWlseT0iR2VvcmdpYSwnVGltZXMgTmV3IFJvbWFuJyxzZXJpZiIgZm9udC1zaXplPSI4OCIgZm9udC13ZWlnaHQ9IjcwMCIgZmlsbD0iIzBGNzY2RSI+dXA8L3RleHQ+PHBhdGggZD0iTTMwIDEwNnExMjAgMjIgMjQwIDAiIGZpbGw9Im5vbmUiIHN0cm9rZT0iIzBEOTQ4OCIgc3Ryb2tlLXdpZHRoPSI2IiBzdHJva2UtbGluZWNhcD0icm91bmQiLz48L3N2Zz4="
)

var examples = []struct{ label, text string }{
	{"A password", "my password is eagle1907"},
	{"Spanish password", "mi contraseña es aguila55"},
	{"A phone number", "call me at 0532 123 45 67"},
	{"Just a story", "Today I raced a snail and we tied."},
	{"Harmless", "I forgot my password again"},
}

// Render paths:
//   ""                 home
//   "check?text=<t>"   result from the form
//   "check/<t>"        result from a plain link
func Render(path string) string {
	if strings.HasPrefix(path, "check") {
		return renderCheck(textOf(path))
	}
	return renderHome()
}

func textOf(path string) string {
	if strings.HasPrefix(path, "check/") {
		s, err := url.PathUnescape(strings.TrimPrefix(path, "check/"))
		if err != nil {
			return strings.TrimPrefix(path, "check/")
		}
		return s
	}
	i := strings.Index(path, "?")
	if i < 0 {
		return ""
	}
	q, err := url.ParseQuery(path[i+1:])
	if err != nil {
		return ""
	}
	return q.Get("text")
}

func form() string {
	return "<gno-form path=\"check\">\n" +
		"  <gno-input name=\"text\" placeholder=\"Paste a message to check before you store it\" />\n" +
		"</gno-form>\n\n"
}

func renderHome() string {
	out := "![soup](" + logo + ")\n\n"
	out += "**A safety check for messages, before your realm stores them.**\n\n"
	out += "> [!WARNING] Everything written to a realm is public and permanent\n" +
		"> One user pasting a seed phrase, a password or a phone number into a board can never take it back. " +
		"soup reads the message first, so your realm can say no.\n\n"

	out += "## <gno-icon name=\"search\" /> Try it\n\n"
	out += form()
	out += "Or try one:\n\n"
	for _, e := range examples {
		out += "<gno-button href=\"" + selfPath + ":check/" + url.PathEscape(e.text) + "\" label=\"" + e.label + "\" variant=\"outline\" />\n"
	}
	out += "\nA check here is a free query and nothing is written on chain. Test with made-up text: the sentence travels in the page address.\n\n"

	out += "## What soup looks for\n\n"
	out += "<gno-columns>\n<gno-frame>\n\n" +
		"### <gno-icon name=\"key\" /> Secrets\n\n" +
		"Passwords, PINs, one-time codes, seed words, private keys, phone numbers, e-mails, IBANs and wallet addresses. In 10 languages.\n\n" +
		"</gno-frame>\n<gno-columns-sep>\n<gno-frame>\n\n" +
		"### <gno-icon name=\"warning-triangle\" /> Toxic\n\n" +
		"Profanity, insults and threats, including spellings that hide them: s4l4k, salaaak, s.a.l.a.k.\n\n" +
		"</gno-frame>\n<gno-columns-sep>\n<gno-frame>\n\n" +
		"### <gno-icon name=\"smile\" /> Flavor\n\n" +
		"The tone of a message: sweet, bitter, sour, salty or spicy, with a confidence. A small neural network, on chain.\n\n" +
		"</gno-frame>\n</gno-columns>\n\n"

	out += "## <gno-icon name=\"code\" /> Use it in your realm\n\n"
	out += "```go\nimport soup \"" + pkgPath + "\"\n\n" +
		"func Post(cur realm, text string) {\n" +
		"\tif !soup.Safe(text) {\n" +
		"\t\tpanic(\"message blocked: it leaks a secret or is toxic\")\n" +
		"\t}\n" +
		"\t// store the message\n" +
		"}\n```\n\n"
	out += "About 42M gas for a normal message. The package stores nothing and writes nothing.\n\n"

	out += "## <gno-icon name=\"heart\" /> Feed the soup\n\n"
	out += "soup gets better with every language. Add the words people use where you live, a flavor example, " +
		"or a test case it got wrong, and open a pull request. Accepted changes ship in the next version.\n\n"
	out += "<gno-button href=\"" + repo + "\" label=\"Source and tests on GitHub\" />\n\n"

	out += "---\n\nPackage `" + pkgPath + "` · version **" + filter.Version + "**\n"
	return out
}

func renderCheck(text string) string {
	out := "![soup](" + logo + ")\n\n"
	if strings.TrimSpace(text) == "" {
		return out + "Type a message first.\n\n" + form()
	}
	toxic, secret, flavor, conf := filter.Check(text)
	switch {
	case secret != "":
		out += "> [!CAUTION] Blocked: it leaks a secret (" + secret + ")\n> Do not store this message.\n\n"
	case toxic != "":
		out += "> [!CAUTION] Blocked: it is toxic (" + toxic + ")\n> Do not store this message.\n\n"
	default:
		out += "> [!SUCCESS] Safe to store\n> No secret, nothing toxic.\n\n"
	}
	out += "| Check | Result |\n|---|---|\n"
	out += "| secret | " + dash(secret) + " |\n"
	out += "| toxic | " + dash(toxic) + " |\n"
	out += "| flavor | " + dash(flavor) + " (" + ufmt.Sprintf("%d", conf) + "% sure) |\n\n"
	out += "Nothing was written on chain. Use made-up text here, never a real secret: the sentence is part of the page address.\n\n"
	out += "Check another:\n\n" + form()
	out += "<gno-button href=\"" + selfPath + "\" label=\"Back to soup\" variant=\"outline\" />\n"
	return out
}

func dash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}
