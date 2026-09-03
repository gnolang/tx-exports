package storage

type Store map[string]string

var store Store

func init() {
	store = make(Store)
}

func Set(key, value string) {
	store[key] = value
}

func Get(key string) string {
	return store[key]
}

func Delete(key string) {
	delete(store, key)
}

func Render(_ string) string {
	out := "storage:\n"
	for k, v := range store {
		out += "  " + k + " = " + v + "\n"
	}
	return out
}
