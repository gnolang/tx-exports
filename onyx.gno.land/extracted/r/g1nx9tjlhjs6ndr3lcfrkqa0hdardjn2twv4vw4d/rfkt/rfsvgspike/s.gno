package rfsvgspike

import "gno.land/r/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/rfkt/rfarena"

var registered = -1

const rawSVG = `<svg xmlns="http://www.w3.org/2000/svg" width="160" height="160" viewBox="0 0 16 16"><rect width="16" height="16" fill="#111"/><path d="M2 8 H8 V3" stroke="#f0f" stroke-width="0.8" fill="none" stroke-dasharray="20" stroke-dashoffset="20"><animate attributeName="stroke-dashoffset" from="20" to="0" dur="2s" repeatCount="indefinite"/></path><path d="M13 7 H8 V13" stroke="#0ff" stroke-width="0.8" fill="none" style="stroke-dasharray:20;stroke-dashoffset:20;animation:d 2s linear infinite"/><style>@keyframes d{to{stroke-dashoffset:0}}</style></svg>`

func init(cur realm) {
	registered = rfarena.Register(cross(cur), nil)
}

func Render(path string) string {
	return "# svg spike\n\nregistered id from init: " + itoa(registered) + "\n\n![anim](data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIxNjAiIGhlaWdodD0iMTYwIiB2aWV3Qm94PSIwIDAgMTYgMTYiPjxyZWN0IHdpZHRoPSIxNiIgaGVpZ2h0PSIxNiIgZmlsbD0iIzExMSIvPjxwYXRoIGQ9Ik0yIDggSDggVjMiIHN0cm9rZT0iI2YwZiIgc3Ryb2tlLXdpZHRoPSIwLjgiIGZpbGw9Im5vbmUiIHN0cm9rZS1kYXNoYXJyYXk9IjIwIiBzdHJva2UtZGFzaG9mZnNldD0iMjAiPjxhbmltYXRlIGF0dHJpYnV0ZU5hbWU9InN0cm9rZS1kYXNob2Zmc2V0IiBmcm9tPSIyMCIgdG89IjAiIGR1cj0iMnMiIHJlcGVhdENvdW50PSJpbmRlZmluaXRlIi8+PC9wYXRoPjxwYXRoIGQ9Ik0xMyA3IEg4IFYxMyIgc3Ryb2tlPSIjMGZmIiBzdHJva2Utd2lkdGg9IjAuOCIgZmlsbD0ibm9uZSIgc3R5bGU9InN0cm9rZS1kYXNoYXJyYXk6MjA7c3Ryb2tlLWRhc2hvZmZzZXQ6MjA7YW5pbWF0aW9uOmQgMnMgbGluZWFyIGluZmluaXRlIi8+PHN0eWxlPkBrZXlmcmFtZXMgZHt0b3tzdHJva2UtZGFzaG9mZnNldDowfX08L3N0eWxlPjwvc3ZnPg==)\n\nraw:\n\n" + rawSVG + "\n"
}

func itoa(n int) string {
	if n < 0 {
		return "-" + itoa(-n)
	}
	if n < 10 {
		return string(rune('0' + n))
	}
	return itoa(n/10) + string(rune('0'+n%10))
}
