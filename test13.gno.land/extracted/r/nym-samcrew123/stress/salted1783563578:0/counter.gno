package counter

import "strconv"

type Counter struct {
	Value int
}

func (c *Counter) Inc() {
	c.Value++
}

var c Counter

func Increment() {
	c.Inc()
}

func Render(path string) string {
	return "Compteur Samourai : " + strconv.Itoa(c.Value)
}
