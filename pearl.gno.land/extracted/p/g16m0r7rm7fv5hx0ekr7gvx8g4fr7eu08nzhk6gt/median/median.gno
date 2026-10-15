package median

type Window struct {
	data []int64
	size int
}

func NewWindow(size int) *Window {
	return &Window{data: make([]int64, 0, size), size: size}
}

func (w *Window) Push(v int64) {
	w.data = append(w.data, v)
	if len(w.data) > w.size {
		w.data = w.data[1:]
	}
}

func (w *Window) Median() int64 {
	n := len(w.data)
	if n == 0 {
		return 0
	}
	sorted := make([]int64, n)
	copy(sorted, w.data)
	for i := 1; i < n; i++ {
		key := sorted[i]
		j := i - 1
		for j >= 0 && sorted[j] > key {
			sorted[j+1] = sorted[j]
			j--
		}
		sorted[j+1] = key
	}
	if n%2 == 1 {
		return sorted[n/2]
	}
	return (sorted[n/2-1] + sorted[n/2]) / 2
}

func (w *Window) Len() int {
	return len(w.data)
}
