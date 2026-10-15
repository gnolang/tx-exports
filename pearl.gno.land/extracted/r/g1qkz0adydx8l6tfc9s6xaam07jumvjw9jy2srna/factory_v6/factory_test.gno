package factory_v6

import (
	"strings"
	"testing"
)

func TestCompile(t *testing.T) {
	// If this compiles, we've succeeded
	symbol, _ := validateSymbol("TEST")
	if symbol != "TEST" {
		t.Fatalf("expected TEST, got %s", symbol)
	}
}

func TestTokenAmountsUseWholeUnits(t *testing.T) {
	if TOKEN_DECIMALS != 0 {
		t.Fatalf("TOKEN_DECIMALS = %d, want 0 so curve units equal display tokens", TOKEN_DECIMALS)
	}
	if MAX_SUPPLY != 300000000 {
		t.Fatalf("MAX_SUPPLY = %d, want 300000000 whole tokens", MAX_SUPPLY)
	}
}

func TestSymbolValidation(t *testing.T) {
	tests := []struct {
		input string
		want  string
		fail  bool
	}{
		{"TEST", "TEST", false},
		{"test", "TEST", false},
		{"A", "", true},              // too short
		{"AB", "", true},             // too short
		{"ABC", "ABC", false},        // minimum length
		{"ABCD", "ABCD", false},      // maximum length
		{"ABCDE", "", true},          // too long
		{"VERYLONGSYMBOL", "", true}, // too long
		{"TEST!", "", true},          // invalid char
		{"123", "123", false},
		{"ABC123", "", true}, // too long
	}

	for _, tt := range tests {
		got, err := validateSymbol(tt.input)
		if tt.fail {
			if err == nil {
				t.Errorf("validateSymbol(%q) should fail", tt.input)
			}
		} else {
			if err != nil {
				t.Errorf("validateSymbol(%q) failed: %v", tt.input, err)
			}
			if got != tt.want {
				t.Errorf("validateSymbol(%q) = %q, want %q", tt.input, got, tt.want)
			}
		}
	}
}

func TestNameValidation(t *testing.T) {
	tests := []struct {
		input string
		want  string
		fail  bool
	}{
		{"Test Token", "Test Token", false},
		{"", "", true},
		{"  X  ", "X", false},
		{"bad\nname", "", true},
	}

	for _, tt := range tests {
		got, err := validateName(tt.input)
		if tt.fail {
			if err == nil {
				t.Errorf("validateName(%q) should fail", tt.input)
			}
		} else {
			if err != nil {
				t.Errorf("validateName(%q) failed: %v", tt.input, err)
			}
			if got != tt.want {
				t.Errorf("validateName(%q) = %q, want %q", tt.input, got, tt.want)
			}
		}
	}
}

func TestMetadataValidation(t *testing.T) {
	if _, err := validateDescription("line one\nPrice: 0"); err == nil {
		t.Error("description control characters must be rejected")
	}
	if _, err := validateDescription(strings.Repeat("a", MAX_DESCRIPTION_LEN+1)); err == nil {
		t.Error("oversized descriptions must be rejected rather than truncated")
	}
	if got, err := validateImageURL("ipfs://bafy-test"); err != nil || got != "ipfs://bafy-test" {
		t.Errorf("valid IPFS image rejected: %q, %v", got, err)
	}
	if _, err := validateImageURL("http://insecure.example/logo.png"); err == nil {
		t.Error("insecure image URL must be rejected")
	}
	if _, err := validateSocialURL("javascript:alert(1)"); err == nil {
		t.Error("unsafe social URL must be rejected")
	}
}

func TestPriceAtSupply(t *testing.T) {
	// spotPrice(S) = S / SLOPE_A + BASE_B = S / 100 + 1
	price := spotPrice(0)
	if price != 1 {
		t.Errorf("spotPrice(0) = %d, want 1", price)
	}
	price = spotPrice(1000000)
	// 1000000 / 100 + 1 = 10001
	if price != 10001 {
		t.Errorf("spotPrice(1000000) = %d, want 10001", price)
	}
}

func TestAMMFeeIsTwoPercent(t *testing.T) {
	// AMM-SELL-FEE policy: total AMM swap fee is 2% (1% protocol + 1% LP).
	// Quote* read only ammPools, so a direct pool fixture is sufficient.
	ammPools["FEE"] = &AMMPool{
		TokenReserve: 1000000,
		GNOTReserve:  1000000,
		TotalLP:      1000000,
		Active:       true,
	}
	defer delete(ammPools, "FEE")

	// Buy: 1,000,000 ugnot in -> 1% (10000) protocol + 1% (10000) LP = 20000.
	_, buyFee := QuoteAMMBuy("FEE", 1000000)
	if buyFee != 20000 {
		t.Errorf("QuoteAMMBuy fee = %d, want 20000 (2%%)", buyFee)
	}

	// Sell: grossOut = 1e6*1e6/(1e6+1e6+1) = 499999; fee = 2*floor(499999*1%) = 2*4999 = 9998.
	gnotOut, sellFee := QuoteAMMSell("FEE", 1000000)
	if sellFee != 9998 {
		t.Errorf("QuoteAMMSell fee = %d, want 9998 (2%% of 499999)", sellFee)
	}
	if gnotOut != 499999-9998 {
		t.Errorf("QuoteAMMSell gnotOut = %d, want %d", gnotOut, 499999-9998)
	}
}

func TestFormatBps(t *testing.T) {
	// FMT-1: ufmt does not zero-pad %d, so formatBps pads the fractional part.
	cases := []struct {
		bps  int64
		want string
	}{
		{500, "5.00%"},
		{300, "3.00%"},
		{250, "2.50%"},
		{25, "0.25%"},
		{5, "0.05%"},
		{0, "0.00%"},
	}
	for _, c := range cases {
		if got := formatBps(c.bps); got != c.want {
			t.Errorf("formatBps(%d) = %q, want %q", c.bps, got, c.want)
		}
	}
}

func TestRoyaltyFeeSplit(t *testing.T) {
	recipient := address("g1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq4p0n2m")
	tests := []struct {
		name         string
		fee          int64
		royaltyBps   int64
		recipient    address
		wantProtocol int64
		wantRoyalty  int64
	}{
		{"no royalty", 10000, 0, recipient, 10000, 0},
		{"no recipient", 10000, 500, "", 10000, 0},
		{"one percent of fee", 10000, 100, recipient, 9900, 100},
		{"three percent of fee", 10000, 300, recipient, 9700, 300},
		{"five percent of fee", 10000, 500, recipient, 9500, 500},
		{"rounds down without overpaying", 1, 500, recipient, 1, 0},
	}

	for _, tt := range tests {
		gotProtocol, gotRoyalty := splitTradeFee(tt.fee, tt.royaltyBps, tt.recipient)
		if gotProtocol != tt.wantProtocol {
			t.Errorf("%s protocol = %d, want %d", tt.name, gotProtocol, tt.wantProtocol)
		}
		if gotRoyalty != tt.wantRoyalty {
			t.Errorf("%s royalty = %d, want %d", tt.name, gotRoyalty, tt.wantRoyalty)
		}
		if gotProtocol < 0 {
			t.Errorf("%s protocol fee went negative", tt.name)
		}
		if gotProtocol+gotRoyalty != tt.fee {
			t.Errorf("%s split total = %d, want %d", tt.name, gotProtocol+gotRoyalty, tt.fee)
		}
	}
}
