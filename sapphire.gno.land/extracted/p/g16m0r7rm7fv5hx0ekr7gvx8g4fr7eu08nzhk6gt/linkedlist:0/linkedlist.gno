package linkedlist

// node is a single element of the singly-linked list.
type node struct {
	value int64
	next  *node
}

// List is a simple singly-linked FIFO list of int64 values.
type List struct {
	head *node
	tail *node
	size int
}

// New creates an empty list.
func New() *List {
	return &List{}
}

// PushBack appends a value to the end of the list.
func (l *List) PushBack(v int64) {
	n := &node{value: v}
	if l.tail == nil {
		l.head = n
		l.tail = n
	} else {
		l.tail.next = n
		l.tail = n
	}
	l.size++
}

// PushFront prepends a value to the start of the list.
func (l *List) PushFront(v int64) {
	n := &node{value: v, next: l.head}
	l.head = n
	if l.tail == nil {
		l.tail = n
	}
	l.size++
}

// PopFront removes and returns the value at the front of the list.
func (l *List) PopFront() int64 {
	if l.head == nil {
		panic("linkedlist: pop from empty list")
	}
	v := l.head.value
	l.head = l.head.next
	if l.head == nil {
		l.tail = nil
	}
	l.size--
	return v
}

// Front returns the value at the front without removing it.
func (l *List) Front() int64 {
	if l.head == nil {
		panic("linkedlist: front of empty list")
	}
	return l.head.value
}

// Len returns the number of elements in the list.
func (l *List) Len() int {
	return l.size
}

// IsEmpty reports whether the list has no elements.
func (l *List) IsEmpty() bool {
	return l.size == 0
}

// ToSlice returns a snapshot of all elements from front to back.
func (l *List) ToSlice() []int64 {
	out := make([]int64, 0, l.size)
	cur := l.head
	for cur != nil {
		out = append(out, cur.value)
		cur = cur.next
	}
	return out
}

// Contains reports whether v exists anywhere in the list.
func (l *List) Contains(v int64) bool {
	cur := l.head
	for cur != nil {
		if cur.value == v {
			return true
		}
		cur = cur.next
	}
	return false
}

// RemoveFirst removes the first occurrence of v, if present. Returns true if removed.
func (l *List) RemoveFirst(v int64) bool {
	if l.head == nil {
		return false
	}
	if l.head.value == v {
		l.PopFront()
		return true
	}
	prev := l.head
	cur := l.head.next
	for cur != nil {
		if cur.value == v {
			prev.next = cur.next
			if cur == l.tail {
				l.tail = prev
			}
			l.size--
			return true
		}
		prev = cur
		cur = cur.next
	}
	return false
}
