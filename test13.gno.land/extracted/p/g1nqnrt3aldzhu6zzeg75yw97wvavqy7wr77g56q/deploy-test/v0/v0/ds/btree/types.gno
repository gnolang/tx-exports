package btree

type key interface {
	Less(than key) bool
}

type stringKey string

var _ key = (stringKey)("")

func (s stringKey) Less(than key) bool {
	return s < than.(stringKey)
}

type uint32Key uint32

var _ key = (uint32Key)(0)

func (u uint32Key) Less(than key) bool {
	return u < than.(uint32Key)
}

type uint64Key uint64

var _ key = (uint64Key)(0)

func (u uint64Key) Less(than key) bool {
	return u < than.(uint64Key)
}

type int64Key int64

var _ key = (int64Key)(0)

func (u int64Key) Less(than key) bool {
	return u < than.(int64Key)
}

type iterCbFn func(key key, value any) bool
