package gasbench

import (
	"strconv"
	"strings"
)

// Bench counts operations explicitly so results are deterministic inside a VM.
type Bench struct {
	name string
	ops  int
}

type Result struct {
	Name string
	Ops  int
}

func Begin(name string) *Bench { return &Bench{name: name} }

func (b *Bench) AddOps(ops int) {
	if ops < 0 || b.ops+ops < b.ops {
		panic("gasbench: invalid operation count")
	}
	b.ops += ops
}

func (b *Bench) End() Result { return Result{Name: b.name, Ops: b.ops} }

func AssertMaxOps(ops int, max int) {
	if ops < 0 || max < 0 || ops > max {
		panic("gasbench: operation budget exceeded or invalid (ops=" + strconv.Itoa(ops) + ", max=" + strconv.Itoa(max) + ")")
	}
}

func AssertBudget(ops int, max int) { AssertMaxOps(ops, max) }

func FormatMarkdown(results []Result) string {
	var out strings.Builder
	out.WriteString("| Benchmark | Operations |\n| --- | ---: |\n")
	for _, result := range results {
		name := strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", "|", "&#124;", "\n", " ", "\r", " ").Replace(result.Name)
		out.WriteString("| " + name + " | " + strconv.Itoa(result.Ops) + " |\n")
	}
	return out.String()
}
