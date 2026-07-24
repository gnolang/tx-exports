package myinterface

type Storer interface {
    Set(key string, value string)
    Get(key string) string
    Has(key string) bool
}

type SimpleStore struct {
    data map[string]string
}

func NewSimpleStore() *SimpleStore {
    return &SimpleStore{
        data: make(map[string]string),
    }
}

func (s *SimpleStore) Set(key string, value string) {
    s.data[key] = value
}

func (s *SimpleStore) Get(key string) string {
    return s.data[key]
}

func (s *SimpleStore) Has(key string) bool {
    _, exists := s.data[key]
    return exists
}
