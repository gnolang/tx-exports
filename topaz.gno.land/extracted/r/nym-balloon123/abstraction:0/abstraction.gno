package abstraction

// Storage defines the basic key-value storage interface.
type Storage interface {
	Set(key string, value string)
	Get(key string) string
	Has(key string) bool
	Size() int
}
