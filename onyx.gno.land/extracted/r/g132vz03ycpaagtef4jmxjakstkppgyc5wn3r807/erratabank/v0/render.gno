package erratabank

import (
	"strconv"

	"gno.land/p/g132vz03ycpaagtef4jmxjakstkppgyc5wn3r807/errata/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/mux/v0"
	"gno.land/p/nt/ufmt/v0"
)

const pageSize = 20

var router = mux.NewRouter()

func init() {
	router.HandleFunc("", renderHome)
	router.HandleFunc("book/{id}", renderBook)
	router.HandleFunc("book/{id}/pending", renderPending)
	router.HandleFunc("book/{id}/all", renderAll)
	router.HandleFunc("erratum/{id}", renderErratum)
	router.HandleFunc("finder/{addr}", renderFinder)
	router.SetNotFoundHandler(func(w *mux.ResponseWriter, _ *mux.Request) {
		notFound(w, "Page")
	})
}

// Render is the public Markdown entry point for gnoweb.
func Render(path string) string {
	return router.Render(path)
}

func finderURL(addr address) string {
	return realmURL + "finder/" + addr.String()
}

func bookRoute(id int) string {
	return "book/" + strconv.Itoa(id)
}

func erratumURL(id int) string {
	return realmURL + "erratum/" + strconv.Itoa(id)
}

func bookURL(id int) string {
	return realmURL + bookRoute(id)
}

func pageOffset(req *mux.Request, total int) (int, bool) {
	value := req.Query.Get("page")
	if value == "" {
		return 0, true
	}
	page, err := strconv.Atoi(value)
	if err != nil || page < 1 || (page > 1 && page-1 > (total-1)/pageSize) {
		return 0, false
	}
	return (page - 1) * pageSize, true
}

func pagination(w *mux.ResponseWriter, route string, offset, total int) {
	if total <= pageSize {
		return
	}
	page := offset/pageSize + 1
	last := (total-1)/pageSize + 1
	w.Write(ufmt.Sprintf("\nPage %d of %d", page, last))
	if page > 1 {
		w.Write(ufmt.Sprintf(" · [Previous](%s%s?page=%d)", realmURL, route, page-1))
	}
	if page < last {
		w.Write(ufmt.Sprintf(" · [Next](%s%s?page=%d)", realmURL, route, page+1))
	}
	w.Write("\n")
}

func notFound(w *mux.ResponseWriter, item string) {
	w.Write("# " + item + " not found\n\n[Erratabank home](" + realmURL + ")\n")
}

func renderHome(w *mux.ResponseWriter, req *mux.Request) {
	offset, ok := pageOffset(req, books.Size())
	if !ok {
		notFound(w, "Page")
		return
	}
	w.Write("# Erratabank\n\n")
	w.Write("Erratabank is a public errata page for books, courses, and technical docs.\n\n")
	w.Write("Each accepted correction credits its finder. Authors can escrow a reward for accepted reports.\n\n")
	w.Write("Use the Actions tab to register a book, submit a correction, or review reports for a book you own.\n\n")
	w.Write("## Books\n\n")
	if books.Size() == 0 {
		w.Write("No books registered yet.\n")
	} else {
		w.Write("| Book | Owner | Reward per erratum | Escrow | Accepted |\n")
		w.Write("| --- | --- | ---: | ---: | ---: |\n")
		for _, book := range ListBooks(offset, pageSize) {
			w.Write(ufmt.Sprintf("| [%s](%s) | %s | %s | %s | %d |\n",
				sanitize.TableCell(book.Title), bookURL(book.ID), errata.ShortAddr(book.Owner.String()),
				errata.FormatUgnot(book.RewardPerErratum), errata.FormatUgnot(book.Escrow),
				requireBook(book.ID).accepted.Size()))
		}
		pagination(w, "", offset, books.Size())
	}
	w.Write("\nStarted 23 Nov 2026 for Gnome Tavern.\n")
}

func routeBook(w *mux.ResponseWriter, req *mux.Request) *bookRecord {
	if id, err := strconv.Atoi(req.GetVar("id")); err == nil {
		if record := bookByID(id); record != nil {
			return record
		}
	}
	notFound(w, "Book")
	return nil
}

func renderBook(w *mux.ResponseWriter, req *mux.Request) {
	record := routeBook(w, req)
	if record == nil {
		return
	}
	offset, ok := pageOffset(req, record.accepted.Size())
	if !ok {
		notFound(w, "Page")
		return
	}
	book := record.book
	state := "Closed"
	if book.Open {
		state = "Open"
	}
	w.Write(ufmt.Sprintf("# %s\n\n- Edition: %s\n- Owner: %s\n- Submissions: %s\n- Reward per erratum: %s\n- Escrow left: %s\n",
		sanitize.InlineText(book.Title), sanitize.InlineText(book.Edition), sanitize.InlineCode(book.Owner.String()),
		state, errata.FormatUgnot(book.RewardPerErratum), errata.FormatUgnot(book.Escrow)))
	if url := sanitize.URL(book.Link); url != "" {
		w.Write("- [Read the book](" + url + ")\n")
	}
	w.Write("\n")
	w.Write(errata.RenderSection("Accepted errata", AcceptedEntriesPage(book.ID, offset, pageSize)))
	pagination(w, bookRoute(book.ID), offset, record.accepted.Size())
	w.Write(ufmt.Sprintf("\n[Pending (%d)](%s/pending) · [All reports (%d)](%s/all) · Rejected: %d · Duplicates: %d · [All books](%s)\n",
		record.pending.Size(), bookURL(book.ID), record.all.Size(), bookURL(book.ID),
		record.rejected.Size(), record.duplicate.Size(), realmURL))
}

func renderPending(w *mux.ResponseWriter, req *mux.Request) {
	renderReportList(w, req, Pending, "Pending reports", "/pending")
}

func renderAll(w *mux.ResponseWriter, req *mux.Request) {
	renderReportList(w, req, "", "All reports", "/all")
}

func renderReportList(w *mux.ResponseWriter, req *mux.Request, status, heading, suffix string) {
	record := routeBook(w, req)
	if record == nil {
		return
	}
	tree := record.reports(status)
	offset, ok := pageOffset(req, tree.Size())
	if !ok {
		notFound(w, "Page")
		return
	}
	book := record.book
	w.Write(ufmt.Sprintf("# %s\n\n[Back to %s](%s)\n\n",
		heading, sanitize.InlineText(book.Title), bookURL(book.ID)))
	if tree.Size() == 0 {
		w.Write("No reports here yet.\n")
		return
	}
	w.Write("| Report | Location | Status | Finder | Height found |\n| --- | --- | --- | --- | ---: |\n")
	for _, report := range listReports(tree, offset, pageSize) {
		w.Write(ufmt.Sprintf("| [#%d](%s) | %s | %s | [%s](%s) | %d |\n",
			report.ID, erratumURL(report.ID), sanitize.TableCell(report.Location), report.Status,
			errata.ShortAddr(report.Finder.String()), finderURL(report.Finder), report.SubmittedAt))
	}
	pagination(w, bookRoute(book.ID)+suffix, offset, tree.Size())
}

func renderErratum(w *mux.ResponseWriter, req *mux.Request) {
	id, err := strconv.Atoi(req.GetVar("id"))
	report, ok := GetErratum(id)
	if err != nil || !ok {
		notFound(w, "Erratum")
		return
	}
	book, _ := GetBook(report.BookID)
	w.Write(ufmt.Sprintf("# Erratum #%d\n\n[Back to %s](%s)\n\n",
		id, sanitize.InlineText(book.Title), bookURL(book.ID)))
	w.Write(ufmt.Sprintf("- Location: %s\n- Finder: [%s](%s)\n- Status: %s\n- Paid: %s\n\n## Correction\n\n%s\n\n",
		sanitize.InlineText(report.Location), report.Finder.String(), finderURL(report.Finder),
		report.Status, errata.FormatUgnot(report.Paid), sanitize.InlineText(report.Text)))
	w.Write(ufmt.Sprintf("## Status history\n\n- Height %d — Pending (submitted)\n", report.SubmittedAt))
	if report.Status != Pending {
		w.Write(ufmt.Sprintf("- Height %d — %s\n", report.ReviewedAt, report.Status))
	}
	if report.Note != "" {
		w.Write("- Review note: " + sanitize.InlineText(report.Note) + "\n")
	}
	if report.DuplicateOf != 0 {
		w.Write(ufmt.Sprintf("- Earlier report: [#%d](%s)\n", report.DuplicateOf, erratumURL(report.DuplicateOf)))
	}
}

func renderFinder(w *mux.ResponseWriter, req *mux.Request) {
	raw := req.GetVar("addr")
	cleaned := sanitize.BechString(raw, "g")
	if cleaned == "" || cleaned != raw || !address(cleaned).IsValid() {
		notFound(w, "Finder")
		return
	}
	finder, _ := finders.Get(cleaned).(*finderRecord)
	count, paid := FinderStats(address(cleaned))
	offset, ok := pageOffset(req, count)
	if !ok {
		notFound(w, "Page")
		return
	}
	w.Write(ufmt.Sprintf("# Finder account\n\n%s\n\n- Accepted finds: %d\n- Total earned: %s\n\n",
		sanitize.InlineCode(cleaned), count, errata.FormatUgnot(paid)))
	if finder == nil {
		w.Write("No accepted finds yet.\n")
		return
	}
	w.Write("| Book | Find | Height found | Paid |\n| --- | --- | ---: | ---: |\n")
	makeFinderRows(w, listReports(&finder.ids, offset, pageSize))
	pagination(w, "finder/"+cleaned, offset, count)
}

func makeFinderRows(w *mux.ResponseWriter, reports []Erratum) {
	for _, report := range reports {
		book, _ := GetBook(report.BookID)
		w.Write(ufmt.Sprintf("| [%s](%s) | [%s](%s) | %d | %s |\n",
			sanitize.TableCell(book.Title), bookURL(book.ID),
			sanitize.TableCell(report.Location), erratumURL(report.ID), report.SubmittedAt,
			errata.FormatUgnot(report.Paid)))
	}
}
