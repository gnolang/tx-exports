// Package erratabank records corrections, finder credit and book reward escrow.
package erratabank

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"unicode/utf8"

	"gno.land/p/g132vz03ycpaagtef4jmxjakstkppgyc5wn3r807/errata/v0"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
)

const (
	Pending   = "Pending"
	Accepted  = "Accepted"
	Rejected  = "Rejected"
	Duplicate = "Duplicate"

	maxAmount  = 1<<63 - 1
	idKeyWidth = 19
)

type Book struct {
	ID               int
	Owner            address
	Title            string
	Edition          string
	Link             string
	RewardPerErratum int64
	Escrow           int64
	Open             bool
	CreatedAt        int64
}

type Erratum struct {
	ID          int
	BookID      int
	Finder      address
	Location    string
	Text        string
	Status      string
	DuplicateOf int
	SubmittedAt int64
	ReviewedAt  int64
	Paid        int64
	Note        string
}

// Each book indexes all reports and each status by submission ID.
type bookRecord struct {
	book      Book
	all       avl.Tree
	pending   avl.Tree
	accepted  avl.Tree
	rejected  avl.Tree
	duplicate avl.Tree
}

func (record *bookRecord) reports(status string) *avl.Tree {
	switch status {
	case "":
		return &record.all
	case Pending:
		return &record.pending
	case Accepted:
		return &record.accepted
	case Rejected:
		return &record.rejected
	case Duplicate:
		return &record.duplicate
	}
	return nil
}

type finderRecord struct {
	paid int64
	ids  avl.Tree
}

var (
	books         = avl.NewTree()
	errataByID    = avl.NewTree()
	finders       = avl.NewTree()
	nextErratumID int
	realmURL      string
)

func init(cur realm) {
	realmURL = strings.TrimPrefix(cur.PkgPath(), "gno.land") + ":"
}

func idKey(id int) string {
	digits := strconv.Itoa(id)
	return strings.Repeat("0", idKeyWidth-len(digits)) + digits
}

func bookByID(id int) *bookRecord {
	if id <= 0 {
		return nil
	}
	book, _ := books.Get(idKey(id)).(*bookRecord)
	return book
}

func reportByID(id int) *Erratum {
	if id <= 0 {
		return nil
	}
	report, _ := errataByID.Get(idKey(id)).(*Erratum)
	return report
}

func requireBook(id int) *bookRecord {
	record := bookByID(id)
	if record == nil {
		panic(errBookMissing)
	}
	return record
}

func requireOwner(record *bookRecord, caller address) {
	if record.book.Owner != caller {
		panic(errOwnerOnly)
	}
}

func requireReview(id int, caller address) (*bookRecord, *Erratum) {
	report := reportByID(id)
	if report == nil {
		panic(errErratumMiss)
	}
	record := requireBook(report.BookID)
	requireOwner(record, caller)
	if report.Status != Pending {
		panic(errPendingOnly)
	}
	return record, report
}

func callerAddress(cur realm) address {
	if !cur.IsCurrent() {
		panic(errCurrentRealm)
	}
	return cur.Previous().Address()
}

// A direct MsgCall credits this realm with the transaction's send before execution.
func inboundUgnot(cur realm) int64 {
	if !cur.Previous().IsUserCall() {
		panic(errDirectCall)
	}
	coins := unsafe.OriginSend()
	if len(coins) == 0 {
		return 0
	}
	if len(coins) != 1 || coins[0].Denom != "ugnot" {
		panic(errPaymentDenom)
	}
	if coins[0].Amount <= 0 {
		panic(errPayment)
	}
	return coins[0].Amount
}

func rejectCoins(cur realm) {
	if cur.Previous().IsUserCall() && len(unsafe.OriginSend()) != 0 {
		panic(errRejectCoins)
	}
}

func addAmount(total, amount int64) int64 {
	if amount > maxAmount-total {
		panic(errOverflow)
	}
	return total + amount
}

func sendUgnot(cur realm, to address, amount int64) {
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), to, chain.NewCoins(chain.NewCoin("ugnot", amount)))
}

func requiredText(field, text string, max int) string {
	trimmed := strings.TrimSpace(text)
	if trimmed == "" || !utf8.ValidString(text) || utf8.RuneCountInString(text) > max {
		panic(field + " must contain 1 to " + strconv.Itoa(max) + " characters")
	}
	return trimmed
}

func reviewNote(note string) string {
	if strings.TrimSpace(note) == "" {
		return ""
	}
	return requiredText("review note", note, 300)
}

// CreateBook registers an open book and optionally credits inbound reward escrow.
func CreateBook(cur realm, title, edition, link string, rewardPerErratum int64) int {
	owner := callerAddress(cur)
	escrow := inboundUgnot(cur)
	title = requiredText("title", title, 120)
	edition = requiredText("edition", edition, 120)
	link = requiredText("link", link, 300)
	if sanitize.URL(link) == "" {
		panic("unsupported book link")
	}
	if rewardPerErratum < 0 {
		panic("reward cannot be negative")
	}
	id := books.Size() + 1
	books.Set(idKey(id), &bookRecord{book: Book{
		ID: id, Owner: owner, Title: title, Edition: edition, Link: link,
		RewardPerErratum: rewardPerErratum, Escrow: escrow, Open: true, CreatedAt: runtime.ChainHeight(),
	}})
	chain.Emit("BookCreated", "book", strconv.Itoa(id), "owner", owner.String(),
		"reward", strconv.FormatInt(rewardPerErratum, 10), "escrow", strconv.FormatInt(escrow, 10))
	return id
}

// FundBook credits a book with ugnot supplied by any direct caller.
func FundBook(cur realm, bookID int) {
	caller := callerAddress(cur)
	amount := inboundUgnot(cur)
	if amount == 0 {
		panic(errPayment)
	}
	record := requireBook(bookID)
	record.book.Escrow = addAmount(record.book.Escrow, amount)
	chain.Emit("BookFunded", "book", strconv.Itoa(bookID), "funder", caller.String(),
		"amount", strconv.FormatInt(amount, 10))
}

// Submit records a report. Increasing IDs break ties within a block.
func Submit(cur realm, bookID int, location, text string) int {
	finder := callerAddress(cur)
	rejectCoins(cur)
	record := requireBook(bookID)
	if !record.book.Open {
		panic(errClosed)
	}
	if finder == record.book.Owner {
		panic(errSelfSubmit)
	}
	location = requiredText("location", location, 120)
	text = requiredText("text", text, 1000)
	nextErratumID++
	id := nextErratumID
	key := idKey(id)
	errataByID.Set(key, &Erratum{
		ID: id, BookID: bookID, Finder: finder, Location: location, Text: text,
		Status: Pending, SubmittedAt: runtime.ChainHeight(),
	})
	record.all.Set(key, id)
	record.pending.Set(key, id)
	chain.Emit("ErratumSubmitted", "book", strconv.Itoa(bookID), "erratum", strconv.Itoa(id),
		"finder", finder.String())
	return id
}

func review(record *bookRecord, report *Erratum, status, note string) {
	key := idKey(report.ID)
	record.pending.Remove(key)
	record.reports(status).Set(key, report.ID)
	report.Status = status
	report.ReviewedAt = runtime.ChainHeight()
	report.Note = note
}

// Accept credits the finder and pays the full reward when escrow covers it.
func Accept(cur realm, erratumID int, note string) {
	owner := callerAddress(cur)
	rejectCoins(cur)
	record, report := requireReview(erratumID, owner)
	review(record, report, Accepted, reviewNote(note))

	addr := report.Finder.String()
	finder, ok := finders.Get(addr).(*finderRecord)
	if !ok {
		finder = &finderRecord{}
		finders.Set(addr, finder)
	}
	finder.ids.Set(idKey(erratumID), erratumID)
	reward := record.book.RewardPerErratum
	if reward > 0 && record.book.Escrow >= reward {
		record.book.Escrow -= reward
		report.Paid = reward
		finder.paid = addAmount(finder.paid, reward)
		sendUgnot(cur, report.Finder, reward)
	}
	chain.Emit("ErratumAccepted", "book", strconv.Itoa(report.BookID), "erratum", strconv.Itoa(erratumID),
		"finder", addr, "paid", strconv.FormatInt(report.Paid, 10))
}

// Reject closes a pending submission without finder credit.
func Reject(cur realm, erratumID int, note string) {
	caller := callerAddress(cur)
	rejectCoins(cur)
	record, report := requireReview(erratumID, caller)
	review(record, report, Rejected, reviewNote(note))
	chain.Emit("ErratumRejected", "book", strconv.Itoa(report.BookID), "erratum", strconv.Itoa(erratumID))
}

// MarkDuplicate links a pending report to an earlier accepted report in the same book.
func MarkDuplicate(cur realm, erratumID, originalID int) {
	caller := callerAddress(cur)
	rejectCoins(cur)
	record, report := requireReview(erratumID, caller)
	original := reportByID(originalID)
	if original == nil || original.BookID != report.BookID || original.ID >= report.ID ||
		original.Status != Accepted {
		panic(errDuplicate)
	}
	report.DuplicateOf = originalID
	review(record, report, Duplicate, "")
	chain.Emit("ErratumMarkedDuplicate", "book", strconv.Itoa(report.BookID), "erratum", strconv.Itoa(erratumID),
		"original", strconv.Itoa(originalID))
}

// SetBookOpen controls new submissions. Existing submissions remain reviewable.
func SetBookOpen(cur realm, bookID int, open bool) {
	caller := callerAddress(cur)
	rejectCoins(cur)
	record := requireBook(bookID)
	requireOwner(record, caller)
	record.book.Open = open
	chain.Emit("BookOpenChanged", "book", strconv.Itoa(bookID), "open", strconv.FormatBool(open))
}

// Withdraw returns unused escrow to the book owner.
func Withdraw(cur realm, bookID int, amount int64) {
	caller := callerAddress(cur)
	rejectCoins(cur)
	record := requireBook(bookID)
	requireOwner(record, caller)
	if amount <= 0 || amount > record.book.Escrow {
		panic(errWithdraw)
	}
	record.book.Escrow -= amount
	sendUgnot(cur, caller, amount)
	chain.Emit("BookWithdrawn", "book", strconv.Itoa(bookID), "owner", caller.String(),
		"amount", strconv.FormatInt(amount, 10))
}

func GetBook(id int) (Book, bool) {
	if record := bookByID(id); record != nil {
		return record.book, true
	}
	return Book{}, false
}

func ListBooks(offset, limit int) []Book {
	var result []Book
	if offset < 0 || limit <= 0 || offset >= books.Size() {
		return result
	}
	if remaining := books.Size() - offset; limit > remaining {
		limit = remaining
	}
	books.IterateByOffset(offset, limit, func(_ string, value any) bool {
		result = append(result, value.(*bookRecord).book)
		return false
	})
	return result
}

func GetErratum(id int) (Erratum, bool) {
	if report := reportByID(id); report != nil {
		return *report, true
	}
	return Erratum{}, false
}

func listReports(tree *avl.Tree, offset, limit int) []Erratum {
	var result []Erratum
	if tree == nil || offset < 0 || limit <= 0 || offset >= tree.Size() {
		return result
	}
	if remaining := tree.Size() - offset; limit > remaining {
		limit = remaining
	}
	tree.IterateByOffset(offset, limit, func(_ string, value any) bool {
		report, _ := GetErratum(value.(int))
		result = append(result, report)
		return false
	})
	return result
}

// ListErrata returns reports in submission order. An empty status selects all reports.
func ListErrata(bookID int, status string, offset, limit int) []Erratum {
	if record := bookByID(bookID); record != nil {
		return listReports(record.reports(status), offset, limit)
	}
	return nil
}

func acceptedEntries(reports []Erratum) []errata.Entry {
	var entries []errata.Entry
	for _, report := range reports {
		entries = append(entries, errata.Entry{
			Location: report.Location, Text: report.Text, Finder: report.Finder.String(),
			FoundAt: report.SubmittedAt, Paid: report.Paid, Link: finderURL(report.Finder),
		})
	}
	return entries
}

func AcceptedEntries(bookID int) []errata.Entry {
	return AcceptedEntriesPage(bookID, 0, int(maxAmount))
}

// AcceptedEntriesPage supports integrations that render a bounded page.
func AcceptedEntriesPage(bookID, offset, limit int) []errata.Entry {
	return acceptedEntries(ListErrata(bookID, Accepted, offset, limit))
}

func FinderStats(addr address) (accepted int, paid int64) {
	if finder, ok := finders.Get(addr.String()).(*finderRecord); ok {
		return finder.ids.Size(), finder.paid
	}
	return 0, 0
}
