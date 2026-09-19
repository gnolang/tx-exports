package datasource

// NewRecordIterator returns an iterator for a list of records.
// The iterator never returns an error and it doesn't modify the slice.
func NewRecordIterator(records []Record) Iterator {
	return &recordIterator{records: records}
}

type recordIterator struct {
	records []Record
	current Record
}

func (it *recordIterator) Err() error     { return nil }
func (it *recordIterator) Record() Record { return it.current }

func (it *recordIterator) Next() bool {
	if len(it.records) == 0 {
		return false
	}

	it.current, it.records = it.records[0], it.records[1:]
	return true
}
