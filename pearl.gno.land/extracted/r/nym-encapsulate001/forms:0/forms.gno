package forms

import (
	"chain"
	"chain/runtime"
	"regexp"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ownable/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/nt/ufmt/v0"
)

var (
	forms      = avl.NewTree() // slug -> *Form
	nextRespID seqid.ID

	slugRe = regexp.MustCompile(`^[a-z0-9]+(-[a-z0-9]+)*$`)
)

// Create publishes a new form under slug, which becomes its ID and its URL
// segment (/r/<ns>/forms:<slug>). Slugs are unique per realm.
//
// Fields are described by four parallel, pipe-separated strings so the call
// stays usable from gnokey and gnoweb without structured arguments:
//
//	labels:   "Name|Why gno.land?|Server type"
//	kinds:    "text|textarea|select"
//	required: "1|1|0"
//	options:  "||cloud,on-prem,data-center"   (comma-separated; only select uses it)
//
// deadline is a chain height after which the form stops accepting responses,
// or 0 for none. onePerAddr limits each address to a single response.
func Create(cur realm, slug, title, description, labels, kinds, required, options string, onePerAddr bool, deadline int64) string {
	return create(cur, slug, title, description, labels, kinds, required, options, onePerAddr, deadline)
}

// CreateForm is Create for the browser: the index page renders it as a gnoweb
// form, one row per field, so nothing has to be typed into the wallet.
//
// Every parameter is a string because gnoweb submits "" for an empty or
// unchecked input, and "" is not a bool or an int64 as far as the VM is
// concerned. Checkboxes send "1" when ticked. Blank rows are skipped; a row
// with an empty kind is text. deadline "" means none.
func CreateForm(cur realm,
	slug, title, description string,
	l1, k1, r1, o1 string,
	l2, k2, r2, o2 string,
	l3, k3, r3, o3 string,
	l4, k4, r4, o4 string,
	l5, k5, r5, o5 string,
	l6, k6, r6, o6 string,
	l7, k7, r7, o7 string,
	l8, k8, r8, o8 string,
	onePerAddr, deadline string,
) string {
	rows := [][4]string{
		{l1, k1, r1, o1}, {l2, k2, r2, o2}, {l3, k3, r3, o3}, {l4, k4, r4, o4},
		{l5, k5, r5, o5}, {l6, k6, r6, o6}, {l7, k7, r7, o7}, {l8, k8, r8, o8},
	}

	var labels, kinds, required, options []string
	for _, row := range rows {
		label := strings.TrimSpace(row[0])
		if label == "" {
			continue
		}
		if strings.Contains(label, "|") || strings.Contains(row[3], "|") {
			panic(ErrPipeInField)
		}

		kind := strings.TrimSpace(row[1])
		if kind == "" {
			kind = string(KindText)
		}

		labels = append(labels, label)
		kinds = append(kinds, kind)
		required = append(required, boolFlag(row[2]))
		options = append(options, strings.TrimSpace(row[3]))
	}

	var dl int64
	if d := strings.TrimSpace(deadline); d != "" {
		n, err := strconv.Atoi(d)
		if err != nil {
			panic(ErrBadDeadline)
		}
		dl = int64(n)
	}

	return create(cur, slug, title, description,
		strings.Join(labels, "|"), strings.Join(kinds, "|"),
		strings.Join(required, "|"), strings.Join(options, "|"),
		boolFlag(onePerAddr) == "1", dl)
}

// boolFlag normalises a yes/no select value (or anything a human or gnokey
// might send) to the "1"/"0" the field-spec parser expects. Anything that is
// not affirmative is false, so an untouched control means "no".
func boolFlag(s string) string {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "1", "true", "on", "yes":
		return "1"
	}
	return "0"
}

func create(cur realm, slug, title, description, labels, kinds, required, options string, onePerAddr bool, deadline int64) string {
	caller := mustUserCaller(cur)

	slug = strings.TrimSpace(slug)
	if len(slug) < MinSlugLen || len(slug) > MaxSlugLen || !slugRe.MatchString(slug) {
		panic(ErrBadSlug)
	}
	if forms.Has(slug) {
		panic(ErrSlugTaken)
	}

	title = strings.TrimSpace(title)
	description = strings.TrimSpace(description)

	if title == "" {
		panic(ErrEmptyTitle)
	}
	if len(title) > MaxTitleLen {
		panic(ErrTitleTooLong)
	}
	if len(description) > MaxDescriptionLen {
		panic(ErrDescriptionTooLong)
	}

	height := runtime.ChainHeight()
	if deadline < 0 || (deadline > 0 && deadline <= height) {
		panic(ErrBadDeadline)
	}

	fields := parseFields(labels, kinds, required, options)

	f := &Form{
		ID:          slug,
		Title:       title,
		Description: description,
		Fields:      fields,
		OnePerAddr:  onePerAddr,
		Deadline:    deadline,
		CreatedAt:   height,
		owner:       ownable.NewWithAddress(caller),
		responses:   avl.NewTree(),
		byAddr:      avl.NewTree(),
	}

	forms.Set(slug, f)

	chain.Emit("FormCreated", "id", slug, "owner", caller.String(), "title", title)

	return slug
}

// Close stops a form from accepting responses. Owner only.
func Close(cur realm, id string) {
	f := mustGetForm(id)
	f.owner.AssertOwnedBy(mustUserCaller(cur))

	if f.Closed {
		panic(ErrFormClosed)
	}

	f.Closed = true

	chain.Emit("FormClosed", "id", id)
}

// Reopen lets a closed form accept responses again. Owner only. A form
// whose deadline has passed stays closed regardless.
func Reopen(cur realm, id string) {
	f := mustGetForm(id)
	f.owner.AssertOwnedBy(mustUserCaller(cur))

	if !f.Closed {
		panic(ErrFormOpen)
	}
	if f.Deadline > 0 && runtime.ChainHeight() >= f.Deadline {
		panic(ErrDeadlinePassed)
	}

	f.Closed = false

	chain.Emit("FormReopened", "id", id)
}

// TransferOwnership hands a form to another address. Owner only.
func TransferOwnership(cur realm, id string, to address) {
	f := mustGetForm(id)
	f.owner.AssertOwnedBy(mustUserCaller(cur))

	if err := f.owner.TransferOwnership(0, cur, to); err != nil {
		panic(err)
	}

	chain.Emit("FormTransferred", "id", id, "to", to.String())
}

// GetForm returns a form by ID.
func GetForm(id string) (*Form, bool) {
	raw := forms.Get(id)
	if raw == nil {
		return nil, false
	}

	return raw.(*Form), true
}

// ResponseCount returns the number of responses a form has, or 0 if the
// form does not exist.
func ResponseCount(id string) int {
	f, ok := GetForm(id)
	if !ok {
		return 0
	}

	return f.ResponseCount()
}

// FormCount returns how many forms exist.
func FormCount() int {
	return forms.Size()
}

func mustGetForm(id string) *Form {
	f, ok := GetForm(id)
	if !ok {
		panic(ErrFormNotFound)
	}

	return f
}

// mustUserCaller returns the address of the user account that made the
// call. Only user accounts may create forms or respond: a realm submitting
// on someone's behalf would be attributed to the realm, which is never what
// a form wants.
func mustUserCaller(cur realm) address {
	if !cur.IsCurrent() {
		panic("realm value is not the caller's live cur")
	}

	prev := cur.Previous()
	if !prev.IsUser() {
		panic(ErrNotUserCall)
	}

	return prev.Address()
}

// parseFields decodes the four parallel field-spec strings.
func parseFields(labels, kinds, required, options string) []Field {
	labelList := splitFields(labels)
	kindList := splitFields(kinds)
	reqList := splitFields(required)
	optList := splitFields(options)

	n := len(labelList)
	if n == 0 || (n == 1 && labelList[0] == "") {
		panic(ErrNoFields)
	}
	if n > MaxFields {
		panic(ErrTooManyFields)
	}
	if len(kindList) != n || len(reqList) != n {
		panic(ErrFieldSpecMismatch)
	}
	// options may be omitted entirely when no field is a select.
	if len(optList) != n && !(len(optList) == 1 && optList[0] == "") {
		panic(ErrFieldSpecMismatch)
	}

	fields := make([]Field, 0, n)
	for i := 0; i < n; i++ {
		label := strings.TrimSpace(labelList[i])
		if label == "" {
			panic(ErrEmptyLabel)
		}
		if len(label) > MaxLabelLen {
			panic(ufmt.Errorf("field %d: label is too long", i+1))
		}

		kind := FieldKind(strings.TrimSpace(kindList[i]))
		switch kind {
		case KindText, KindTextarea, KindNumber, KindSelect:
		default:
			panic(ErrBadFieldKind)
		}

		field := Field{
			Label:    label,
			Kind:     kind,
			Required: strings.TrimSpace(reqList[i]) == "1",
		}

		if kind == KindSelect {
			raw := ""
			if len(optList) == n {
				raw = optList[i]
			}
			for _, o := range strings.Split(raw, ",") {
				o = strings.TrimSpace(o)
				if o == "" {
					continue
				}
				if len(o) > MaxOptionLen {
					panic(ufmt.Errorf("field %d: option is too long", i+1))
				}
				field.Options = append(field.Options, o)
			}
			if len(field.Options) == 0 {
				panic(ErrSelectNoOptions)
			}
		}

		fields = append(fields, field)
	}

	return fields
}

func splitFields(s string) []string {
	return strings.Split(s, "|")
}
