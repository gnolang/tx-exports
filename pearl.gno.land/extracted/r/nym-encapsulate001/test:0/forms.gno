package test

import (
	"chain"
	"chain/runtime"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ownable/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/nt/ufmt/v0"
)

var (
	forms      = avl.NewTree() // form id -> *Form
	nextFormID seqid.ID
	nextRespID seqid.ID
)

// Create publishes a new form and returns its ID.
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
func Create(cur realm, title, description, labels, kinds, required, options string, onePerAddr bool, deadline int64) string {
	caller := mustUserCaller(cur)

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

	id := nextFormID.Next()
	f := &Form{
		ID:          id,
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

	forms.Set(id.String(), f)

	chain.Emit("FormCreated", "id", id.String(), "owner", caller.String(), "title", title)

	return id.String()
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
