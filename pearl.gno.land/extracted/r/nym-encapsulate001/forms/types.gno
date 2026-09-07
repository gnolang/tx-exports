package forms

import (
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ownable/v0"
	"gno.land/p/nt/seqid/v0"
)

// FieldKind is the input type a field renders as, and the validation it gets.
type FieldKind string

const (
	KindText     FieldKind = "text"
	KindTextarea FieldKind = "textarea"
	KindNumber   FieldKind = "number"
	KindSelect   FieldKind = "select"
)

// Limits. Answers are stored on chain and the respondent pays the storage
// deposit for them, so the caps exist to keep that cost predictable rather
// than to save the realm anything.
const (
	MaxFields         = 8
	MaxTitleLen       = 120
	MaxDescriptionLen = 2048
	MaxLabelLen       = 120
	MaxOptionLen      = 120
	MaxTextLen        = 256
	MaxTextareaLen    = 2048
	MaxNumberLen      = 64
)

// Field is one question on a form.
type Field struct {
	Label    string
	Kind     FieldKind
	Required bool
	Options  []string // select only
}

// MaxLen is the longest answer the field accepts.
func (f Field) MaxLen() int {
	switch f.Kind {
	case KindTextarea:
		return MaxTextareaLen
	case KindNumber:
		return MaxNumberLen
	case KindSelect:
		return MaxOptionLen
	default:
		return MaxTextLen
	}
}

// Slug rules. A slug is the form's ID and its URL segment, chosen at creation:
// lowercase letters and digits, single hyphens between words, 3–48 characters.
const (
	MinSlugLen = 3
	MaxSlugLen = 48
)

// Form is a published questionnaire and its responses.
type Form struct {
	ID          string // the slug
	Title       string
	Description string
	Fields      []Field
	OnePerAddr  bool
	Deadline    int64 // chain height; 0 means none
	Closed      bool
	CreatedAt   int64

	owner     *ownable.Ownable
	responses *avl.Tree // response id -> *Response
	byAddr    *avl.Tree // author address -> response id
}

// Owner returns the form owner's address.
func (f *Form) Owner() address {
	return f.owner.Owner()
}

// ResponseCount returns how many responses the form currently holds.
func (f *Form) ResponseCount() int {
	return f.responses.Size()
}

// IsOpen reports whether the form accepts submissions at the given height.
func (f *Form) IsOpen(height int64) bool {
	if f.Closed {
		return false
	}

	return f.Deadline == 0 || height < f.Deadline
}

// Response is one submission to a form. Answers align with Form.Fields.
type Response struct {
	ID      seqid.ID
	Form    string // the form slug
	Author  address
	Height  int64
	Answers []string
}
