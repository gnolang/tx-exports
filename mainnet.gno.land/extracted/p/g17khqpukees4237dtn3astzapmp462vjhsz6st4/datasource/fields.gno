package datasource

// NewFieldsFromMap returns read-only fields for a map of field names and values.
//
// The map is wrapped as is and not copied, so changes made to it by the caller
// are also visible through the returned fields.
func NewFieldsFromMap(m map[string]any) Fields {
	return fields{values: m}
}

type fields struct {
	values map[string]any
}

func (f fields) Has(name string) bool {
	_, found := f.values[name]
	return found
}

func (f fields) Get(name string) (value any, found bool) {
	value, found = f.values[name]
	return value, found
}
