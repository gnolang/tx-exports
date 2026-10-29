package demo

import (
	"std"
	"strings"
	"testing"

	"gno.land/p/testutils"
)

func Test(t *testing.T) {
	test1 := std.Address("g1ah79e3txw2kd2e8dscr2y2ucr888lm3qwm3v6e")
	test2 := std.Address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")

	std.TestSetOrigCaller(test1)

	// check token name.
	{
		got := Slashcoin.GetName()
		expected := "Slashcoin"
		if strings.TrimSpace(got) != strings.TrimSpace(expected) {
			t.Fatalf("expected %q, got %q.", expected, got)
		}
	}

	// check token symbol.
	{
		got := Slashcoin.GetSymbol()
		expected := "SLASH"
		if strings.TrimSpace(got) != strings.TrimSpace(expected) {
			t.Fatalf("expected %q, got %q.", expected, got)
		}
	}

	// check token Decimals.
	{
		got := Slashcoin.GetDecimals()

		expected := 18
		if got != expected {
			t.Fatalf("expected %q, got %q.", expected, got)
		}
	}

	// check token Supply.
	{
		got := Slashcoin.TotalSupply()
		expected := 1000000
		if got != expected {
			t.Fatalf("expected %q, got %q.", expected, got)
		}
	}


	// ACCOUNTS


	// check balance of test1.
	{
		got, _ := Slashcoin.BalanceOf(test1)
		expected := 1000000
		if got != expected {
			t.Fatalf("expected %d, got %d.", expected, got)
		}
	}

	// transfer tokens to test2.
	_ = Slashcoin.Transfer(test2, 1000)

	// check balance of test1.
	{
		got, _ := Slashcoin.BalanceOf(test1)
		expected := 999000
		if got != expected {
			t.Fatalf("expected %d, got %d.", expected, got)
		}
	}

	// check balance of test2.
	{
		got, _ := Slashcoin.BalanceOf(test2)
		expected := 1000
		if got != expected {
			t.Fatalf("expected %d, got %d.", expected, got)
		}
	}



}
