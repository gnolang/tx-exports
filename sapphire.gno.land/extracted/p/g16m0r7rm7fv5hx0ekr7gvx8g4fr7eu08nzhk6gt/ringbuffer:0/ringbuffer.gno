package ringbuffer

// Buffer is a fixed-capacity circular buffer of int64 values.
// When full, pushing a new value overwrites the oldest one.
type Buffer struct {
	data     []int64
	capacity int
	start    int // index of the oldest element
	size     int // number of elements currently stored
}

// New creates a new ring buffer with the given fixed capacity.
func New(capacity int) *Buffer {
	if capacity <= 0 {
		panic("ringbuffer: capacity must be positive")
	}
	return &Buffer{
		data:     make([]int64, capacity),
		capacity: capacity,
		start:    0,
		size:     0,
	}
}

// Push adds a value, overwriting the oldest entry if the buffer is full.
func (b *Buffer) Push(v int64) {
	writeIdx := (b.start + b.size) % b.capacity
	if b.size < b.capacity {
		b.data[writeIdx] = v
		b.size++
	} else {
		b.data[b.start] = v
		b.start = (b.start + 1) % b.capacity
	}
}

// Len returns the number of elements currently stored.
func (b *Buffer) Len() int {
	return b.size
}

// Capacity returns the maximum number of elements the buffer can hold.
func (b *Buffer) Capacity() int {
	return b.capacity
}

// At returns the element at logical index i (0 = oldest, Len()-1 = newest).
func (b *Buffer) At(i int) int64 {
	if i < 0 || i >= b.size {
		panic("ringbuffer: index out of range")
	}
	return b.data[(b.start+i)%b.capacity]
}

// Latest returns the most recently pushed value.
func (b *Buffer) Latest() int64 {
	if b.size == 0 {
		panic("ringbuffer: buffer is empty")
	}
	return b.At(b.size - 1)
}

// ToSlice returns a snapshot of all stored elements, oldest first.
func (b *Buffer) ToSlice() []int64 {
	out := make([]int64, b.size)
	for i := 0; i < b.size; i++ {
		out[i] = b.At(i)
	}
	return out
}

// Sum returns the sum of all stored elements.
func (b *Buffer) Sum() int64 {
	var total int64
	for i := 0; i < b.size; i++ {
		total += b.At(i)
	}
	return total
}

// Average returns the average of all stored elements. Panics if empty.
func (b *Buffer) Average() int64 {
	if b.size == 0 {
		panic("ringbuffer: buffer is empty")
	}
	return b.Sum() / int64(b.size)
}
