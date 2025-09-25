package alerts

import (
	"gno.land/p/demo/ufmt"
)

const (
	TypeError   Type = "alerts-error"
	TypeWarning Type = "alerts-warning"
)

const (
	StyleError = `
.alerts-error {
	padding: .75rem 1.25rem;
	border: 1px solid #f5c6cb;
	background-color: #f8d7da;
	color: #721c24;
	border-radius: .25rem;
}
`
	StyleWarning = `
.alerts-warning {
	padding: .75rem 1.25rem;
	border: 1px solid #ffeeba;
	background-color: #fff3cd;
	color: #856404;
	border-radius: .25rem;
}
`
)

// Type defines the type of alerts.
type Type string

// NewAlert returns HTML for an alert.
func NewAlert(t Type, content string) string {
	var css string
	switch t {
	case TypeWarning:
		css = StyleWarning
	case TypeError:
		css = StyleError
	default:
		panic("unknown alert type")
	}

	return "\n\n" + ufmt.Sprintf(`<p class="%s">%s</p><style>%s</style>`, string(t), content, css) + "\n\n"
}

// NewWarning returns HTML for a warning alert.
func NewWarning(content string) string {
	return NewAlert(TypeWarning, content)
}

// NewError returns HTML for an error alert.
func NewError(content string) string {
	return NewAlert(TypeError, content)
}

// NewLink returns an HTML link.
func NewLink(href, label string) string {
	return ufmt.Sprintf(`<a href="%s">%s</a>`, href, label)
}
