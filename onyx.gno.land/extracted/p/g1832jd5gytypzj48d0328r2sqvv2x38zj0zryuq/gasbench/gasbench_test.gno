package gasbench

import (
	"strings"
	"testing"
)

func TestBegin(t *testing.T) {
	if got := Begin("query").End(); got.Name != "query" || got.Ops != 0 {
		t.Fatal("unexpected initial result")
	}
}

func TestAddOps(t *testing.T) {
	b := Begin("write")
	b.AddOps(2)
	b.AddOps(3)
	if b.End().Ops != 5 {
		t.Fatal("expected five operations")
	}
}

func TestBudgetAtLimit(t *testing.T) { AssertMaxOps(5, 5) }

func TestBudgetExceeded(t *testing.T) {
	defer func() {
		if recover() != "gasbench: operation budget exceeded or invalid (ops=6, max=5)" {
			t.Error("unexpected panic")
		}
	}()
	AssertBudget(6, 5)
}

func TestMarkdown(t *testing.T) {
	if got := FormatMarkdown([]Result{{Name: "a|b", Ops: 7}}); !strings.Contains(got, "| a&#124;b | 7 |") {
		t.Fatal(got)
	}
}
