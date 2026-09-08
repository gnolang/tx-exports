package forms

import (
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/jeronimoalbi/mdform"
	"gno.land/p/moul/md"
	"gno.land/p/moul/mdtable"
	"gno.land/p/moul/txlink"
	"gno.land/p/nt/avl/v0/pager"
	"gno.land/p/nt/mux/v0"
	"gno.land/p/nt/ufmt/v0"
)

const (
	formsPerPage     = 20
	responsesPerPage = 25
)

var router = mux.NewRouter()

func init() {
	router.HandleFunc("", renderIndex)
	router.HandleFunc("{id}", renderForm)
	router.HandleFunc("{id}/responses", renderResponses)
	router.HandleFunc("{id}/responses.csv", renderCSV)
}

// Render routes:
//
//	/r/<ns>/forms                     index of forms
//	/r/<ns>/forms:<id>                a form, fillable in gnoweb
//	/r/<ns>/forms:<id>/responses      its responses, paginated
//	/r/<ns>/forms:<id>/responses.csv  its responses as CSV
func Render(path string) string {
	return router.Render(path)
}

func renderIndex(res *mux.ResponseWriter, req *mux.Request) {
	var b strings.Builder

	b.WriteString(md.H1("Forms"))
	b.WriteString("Publish a form, collect responses on chain, read them back here. ")
	b.WriteString("Respondents fill it in on this page and pay their own storage deposit; ")
	b.WriteString("withdrawing a response refunds it.\n\n")

	if forms.Size() == 0 {
		b.WriteString("_No forms yet._\n\n")
		b.WriteString(renderCreateHelp())
		res.Write(b.String())
		return
	}

	page := pager.NewPager(forms, formsPerPage, true).MustGetPageByPath(req.RawPath)
	height := runtime.ChainHeight()

	table := &mdtable.Table{Headers: []string{"Form", "Status", "Responses", "Fields", "Owner"}}
	for _, item := range page.Items {
		f := item.Value.(*Form)
		table.Append([]string{
			md.Link(f.Title, formURL(f.ID)),
			statusLabel(f, height),
			strconv.Itoa(f.ResponseCount()),
			strconv.Itoa(len(f.Fields)),
			shortAddr(f.Owner()),
		})
	}

	b.WriteString(table.String())
	b.WriteString("\n")
	b.WriteString(page.Picker(req.RawPath))
	b.WriteString("\n\n")
	b.WriteString(renderCreateHelp())

	res.Write(b.String())
}

func renderForm(res *mux.ResponseWriter, req *mux.Request) {
	f, ok := GetForm(req.GetVar("id"))
	if !ok {
		res.Write("Form not found.")
		return
	}

	height := runtime.ChainHeight()
	id := f.ID

	var b strings.Builder

	b.WriteString(md.H1(f.Title))
	if f.Description != "" {
		b.WriteString(f.Description + "\n\n")
	}

	b.WriteString(ufmt.Sprintf("**Status:** %s · **Responses:** %d · **Owner:** `%s`",
		statusLabel(f, height), f.ResponseCount(), f.Owner()))
	if f.Deadline > 0 {
		b.WriteString(ufmt.Sprintf(" · **Closes at height:** %d", f.Deadline))
	}
	if f.OnePerAddr {
		b.WriteString(" · one response per address")
	}
	b.WriteString("\n\n")

	b.WriteString(md.Link("View responses", responsesURL(id)) + " · " +
		md.Link("CSV", csvURL(id)) + "\n\n")

	if f.IsOpen(height) {
		b.WriteString(md.H2("Respond"))
		b.WriteString(renderMDForm(f))
	} else {
		b.WriteString("_This form is not accepting responses._\n\n")
	}

	b.WriteString(md.H3("Owner actions"))
	if f.Closed {
		b.WriteString(md.Link("Reopen", txlink.Call("Reopen", "id", id)))
	} else {
		b.WriteString(md.Link("Close", txlink.Call("Close", "id", id)))
	}
	b.WriteString(" · " + md.Link("Withdraw my response", txlink.Call("Withdraw", "id", id)) + "\n")

	res.Write(b.String())
}

// renderMDForm draws the fillable form. gnoweb turns it into an HTML form
// that calls Submit; each input is named after the Submit parameter it fills.
func renderMDForm(f *Form) string {
	form := mdform.New("exec", "Submit")

	form.Input("id",
		"value", f.ID,
		"readonly", "true",
		"description", "Form ID",
	)

	for i, field := range f.Fields {
		name := "a" + strconv.Itoa(i+1)
		label := field.Label
		if field.Required {
			label += " *"
		}

		switch field.Kind {
		case KindTextarea:
			attrs := []string{"placeholder", label, "rows", "4"}
			if field.Required {
				attrs = append(attrs, "required", "true")
			}
			form.Textarea(name, attrs...)

		case KindSelect:
			for j, opt := range field.Options {
				attrs := []string{"description", label}
				if j == 0 && field.Required {
					attrs = append(attrs, "required", "true")
				}
				form.Select(name, opt, attrs...)
			}

		case KindNumber:
			attrs := []string{"type", "number", "placeholder", label, "description", label}
			if field.Required {
				attrs = append(attrs, "required", "true")
			}
			form.Input(name, attrs...)

		default:
			attrs := []string{"placeholder", label, "description", label}
			if field.Required {
				attrs = append(attrs, "required", "true")
			}
			form.Input(name, attrs...)
		}
	}

	return form.String() + "\n"
}

func renderResponses(res *mux.ResponseWriter, req *mux.Request) {
	f, ok := GetForm(req.GetVar("id"))
	if !ok {
		res.Write("Form not found.")
		return
	}

	var b strings.Builder

	b.WriteString(md.H1(f.Title + " — responses"))
	b.WriteString(ufmt.Sprintf("%d response(s). ", f.ResponseCount()))
	b.WriteString(md.Link("Back to form", formURL(f.ID)) + " · " +
		md.Link("CSV", csvURL(f.ID)) + "\n\n")

	if f.ResponseCount() == 0 {
		b.WriteString("_No responses yet._\n")
		res.Write(b.String())
		return
	}

	headers := []string{"#", "From", "Height"}
	for _, field := range f.Fields {
		headers = append(headers, field.Label)
	}
	table := &mdtable.Table{Headers: headers}

	page := pager.NewPager(f.responses, responsesPerPage, false).MustGetPageByPath(req.RawPath)
	for _, item := range page.Items {
		r := item.Value.(*Response)
		row := []string{r.ID.String(), shortAddr(r.Author), strconv.Itoa(int(r.Height))}
		for _, a := range r.Answers {
			row = append(row, cell(a))
		}
		table.Append(row)
	}

	b.WriteString(table.String())
	b.WriteString("\n")
	b.WriteString(page.Picker(req.RawPath))
	b.WriteString("\n")

	res.Write(b.String())
}

// renderCSV emits every response as CSV inside a code block, so a reviewer
// can copy it straight into a spreadsheet.
func renderCSV(res *mux.ResponseWriter, req *mux.Request) {
	f, ok := GetForm(req.GetVar("id"))
	if !ok {
		res.Write("Form not found.")
		return
	}

	var b strings.Builder

	header := []string{"response_id", "author", "height"}
	for _, field := range f.Fields {
		header = append(header, field.Label)
	}
	b.WriteString(csvRow(header))

	f.responses.Iterate("", "", func(_ string, value any) bool {
		r := value.(*Response)
		row := []string{r.ID.String(), r.Author.String(), strconv.Itoa(int(r.Height))}
		row = append(row, r.Answers...)
		b.WriteString(csvRow(row))
		return false
	})

	res.Write(md.LanguageCodeBlock("csv", b.String()))
}

// renderCreateHelp draws the form that creates forms. gnoweb submits it as a
// CreateForm call with every input mapped to the parameter of the same name.
func renderCreateHelp() string {
	form := mdform.New("exec", "CreateForm")

	form.Input("slug",
		"placeholder", "valoper-questionnaire",
		"description", "URL name — lowercase letters, digits, hyphens",
		"required", "true",
	)
	form.Input("title",
		"placeholder", "Valoper questionnaire",
		"description", "Title",
		"required", "true",
	)
	form.Textarea("description",
		"placeholder", "What this form is for (optional)",
		"rows", "3",
	)

	for i := 1; i <= MaxFields; i++ {
		n := strconv.Itoa(i)
		form.Input("l"+n,
			"placeholder", "Field "+n+" label (leave blank to skip)",
			"description", "Field "+n,
		)
		form.Select("k"+n, string(KindText), "description", "Field "+n+" type", "selected", "true")
		form.Select("k"+n, string(KindTextarea))
		form.Select("k"+n, string(KindNumber))
		form.Select("k"+n, string(KindSelect))
		// A two-option select, not a checkbox: gnoweb sends an untouched
		// checkbox's value attribute as if it were ticked, so every field came
		// out required. Untouched selects correctly send their default.
		form.Select("r"+n, "no", "description", "Field "+n+" required?", "selected", "true")
		form.Select("r"+n, "yes")
		form.Input("o"+n,
			"placeholder", "Options, comma-separated (select fields only)",
			"description", "Field "+n+" options",
		)
	}

	form.Select("onePerAddr", "no", "description", "One response per address?", "selected", "true")
	form.Select("onePerAddr", "yes")
	form.Input("deadline",
		"type", "number",
		"placeholder", "0",
		"description", "Close at chain height (0 = never)",
	)

	return md.H2("Create a form") +
		"Up to " + strconv.Itoa(MaxFields) + " fields. Blank rows are skipped. " +
		"Submitting opens your wallet with the call already filled in.\n\n" +
		form.String() + "\n" +
		"From a terminal, " + md.InlineCode("Create") + " takes the same thing as pipe-separated field specs — see the realm source.\n"
}

// --- helpers ---

func statusLabel(f *Form, height int64) string {
	if f.Closed {
		return "closed"
	}
	if f.Deadline > 0 && height >= f.Deadline {
		return "expired"
	}

	return "open"
}

func formURL(id string) string      { return realmURL() + ":" + id }
func responsesURL(id string) string { return realmURL() + ":" + id + "/responses" }
func csvURL(id string) string       { return realmURL() + ":" + id + "/responses.csv" }

var realmPath = unsafe.CurrentRealm().PkgPath()

// realmURL is this realm's path as gnoweb addresses it, derived from where
// it is deployed rather than hardcoded.
func realmURL() string {
	return strings.TrimPrefix(realmPath, "gno.land")
}

func shortAddr(a address) string {
	s := a.String()
	if len(s) <= 14 {
		return s
	}

	return s[:8] + "…" + s[len(s)-4:]
}

// cell makes an answer safe inside a markdown table cell.
func cell(s string) string {
	s = strings.ReplaceAll(s, "|", "\\|")
	s = strings.ReplaceAll(s, "\n", " ")

	return s
}

// csvRow quotes every field, doubling embedded quotes, per RFC 4180.
func csvRow(fields []string) string {
	out := make([]string, len(fields))
	for i, f := range fields {
		out[i] = `"` + strings.ReplaceAll(f, `"`, `""`) + `"`
	}

	return strings.Join(out, ",") + "\n"
}
