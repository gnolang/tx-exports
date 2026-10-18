package pado

import (
	"strconv"
	"strings"
)

// Render lists the launches in this realm. Quote figures are ugnot.
func Render(path string) string {
	if path != "" && path != "/" {
		return "> [!WARNING]\n> Path not found"
	}
	var b strings.Builder
	b.WriteString("# pado\n\n")
	b.WriteString("No trade tax. Each launch keeps its own raise.\n\n")
	if owner.IsValid() {
		b.WriteString("* **Owner**: ")
		b.WriteString(owner.String())
		b.WriteString("\n")
	}
	b.WriteString("* **Realm**: ")
	b.WriteString(padAddr.String())
	b.WriteString("\n\n")
	n := 0
	launches.Iterate("", "", func(key string, value any) bool {
		l, ok := value.(*launch)
		if !ok || l == nil {
			return false
		}
		n++
		b.WriteString("## ")
		b.WriteString(esc(l.symbol))
		b.WriteString("\n\n")
		b.WriteString("* **id**: ")
		b.WriteString(esc(key))
		b.WriteString("\n* **raise**: ")
		b.WriteString(strconv.FormatInt(l.raiseUgnot, 10))
		b.WriteString("\n* **raised**: ")
		b.WriteString(strconv.FormatInt(l.raisedUgnot, 10))
		b.WriteString("\n* **pool**: ")
		b.WriteString(strconv.FormatInt(l.poolUgnot, 10))
		b.WriteString("\n* **status**: ")
		b.WriteString(strconv.Itoa(l.status))
		b.WriteString("\n\n")
		return false
	})
	if n == 0 {
		b.WriteString("No launches.\n")
	}
	return b.String()
}

func esc(s string) string {
	r := strings.NewReplacer(
		"\n", " ",
		"\r", " ",
		"#", "",
		"[", "",
		"]", "",
		"<", "",
		">", "",
		"|", "/",
	)
	return r.Replace(s)
}
