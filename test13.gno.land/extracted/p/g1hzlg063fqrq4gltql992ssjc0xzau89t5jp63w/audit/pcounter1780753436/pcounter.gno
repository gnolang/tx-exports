package pcounter

type Counter struct{ Value int }

func Inc(c *Counter) { c.Value++ }
