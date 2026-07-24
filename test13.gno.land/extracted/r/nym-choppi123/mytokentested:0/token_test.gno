package mytokentested

import "testing"

func TestGetName(t *testing.T) {
    if GetName() != "MyTokenTested" {
        t.Error("Expected MyTokenTested")
    }
}

func TestGetSymbol(t *testing.T) {
    if GetSymbol() != "MTKT" {
        t.Error("Expected MTKT")
    }
}

func TestGetTotalSupply(t *testing.T) {
    if GetTotalSupply() != 1000000 {
        t.Error("Expected 1000000")
    }
}

func TestBalanceOf(t *testing.T) {
    balance := BalanceOf("g1p4r3esnxhahp307gh5kplvnjxdgy8kguvf9znu")
    if balance != 1000000 {
        t.Error("Expected 1000000")
    }
}

func TestBalanceOfUnknown(t *testing.T) {
    balance := BalanceOf("unknown")
    if balance != 0 {
        t.Error("Expected 0")
    }
}

func TestNameNotEmpty(t *testing.T) {
    if GetName() == "" {
        t.Error("Name should not be empty")
    }
}

func TestSymbolNotEmpty(t *testing.T) {
    if GetSymbol() == "" {
        t.Error("Symbol should not be empty")
    }
}

func TestSupplyPositive(t *testing.T) {
    if GetTotalSupply() <= 0 {
        t.Error("Supply should be positive")
    }
}

func TestBalanceMapExists(t *testing.T) {
    if balances == nil {
        t.Error("Balance map should exist")
    }
}

func TestRenderNotEmpty(t *testing.T) {
    render := Render("")
    if render == "" {
        t.Error("Render should not be empty")
    }
}
