package commitreveal

type Entry struct {
	Commitment string
	Revealed   bool
	Value      string
}

type Registry struct {
	entries map[string]*Entry
}

func NewRegistry() *Registry {
	return &Registry{entries: make(map[string]*Entry)}
}

func (r *Registry) Commit(id string, commitment string) {
	r.entries[id] = &Entry{Commitment: commitment}
}

func (r *Registry) Reveal(id string, value string, hashFn func(string) string) bool {
	e, ok := r.entries[id]
	if !ok || e.Revealed {
		return false
	}
	if hashFn(value) != e.Commitment {
		return false
	}
	e.Revealed = true
	e.Value = value
	return true
}

func (r *Registry) Get(id string) (*Entry, bool) {
	e, ok := r.entries[id]
	return e, ok
}
