package merkle

// non-cryptographic merkle tree using a manual FNV-style mix (no external imports)

func mix(a, b string) string {
	h := uint64(1469598103934665603)
	for i := 0; i < len(a); i++ {
		h ^= uint64(a[i])
		h *= 1099511628211
	}
	for i := 0; i < len(b); i++ {
		h ^= uint64(b[i])
		h *= 1099511628211
	}
	return itoa(h)
}

func leafHash(data string) string {
	h := uint64(1469598103934665603)
	for i := 0; i < len(data); i++ {
		h ^= uint64(data[i])
		h *= 1099511628211
	}
	return itoa(h)
}

type Tree struct {
	Leaves []string
	Root   string
}

func New(data []string) *Tree {
	leaves := make([]string, len(data))
	for i, d := range data {
		leaves[i] = leafHash(d)
	}
	t := &Tree{Leaves: leaves}
	t.Root = buildRoot(leaves)
	return t
}

func buildRoot(level []string) string {
	if len(level) == 0 {
		return ""
	}
	if len(level) == 1 {
		return level[0]
	}
	next := make([]string, 0, (len(level)+1)/2)
	for i := 0; i < len(level); i += 2 {
		if i+1 < len(level) {
			next = append(next, mix(level[i], level[i+1]))
		} else {
			next = append(next, mix(level[i], level[i]))
		}
	}
	return buildRoot(next)
}

func itoa(n uint64) string {
	if n == 0 {
		return "0"
	}
	var buf [24]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	return string(buf[i:])
}
