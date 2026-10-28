package ringbuffer

type RingBuffer struct {
	data  []int64
	size  int
	head  int
	count int
}

func New(size int) *RingBuffer {
	return &RingBuffer{data: make([]int64, size), size: size}
}

func (r *RingBuffer) Push(v int64) {
	r.data[r.head] = v
	r.head = (r.head + 1) % r.size
	if r.count < r.size {
		r.count++
	}
}

func (r *RingBuffer) Items() []int64 {
	out := make([]int64, r.count)
	start := (r.head - r.count + r.size) % r.size
	for i := 0; i < r.count; i++ {
		out[i] = r.data[(start+i)%r.size]
	}
	return out
}

func (r *RingBuffer) Len() int {
	return r.count
}

func (r *RingBuffer) Full() bool {
	return r.count == r.size
}
