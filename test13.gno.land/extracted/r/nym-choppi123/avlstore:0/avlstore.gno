package avlstore

var store map[string]string

func init() {
    store = make(map[string]string)
}

func Set(key string, value string) {
    store[key] = value
}

func Get(key string) string {
    return store[key]
}

func Has(key string) bool {
    _, exists := store[key]
    return exists
}

func Remove(key string) {
    delete(store, key)
}

func Size() int {
    return len(store)
}
