package tavernpay

import "testing"

var (
	testPayer = address("g1h2fd0ykqkfgh6heggn6uh0r9qnxz9ujpka5fce")
	testPayee = address("g1jg8mtutu9khhfwc07hx9gu5w5j9z5hfnw4z6q")
)

func resetState() {
	mandates = nil
	nextID = 1
}

func expectPanic(t *testing.T, name string, fn func()) {
	defer func() {
		if r := recover(); r == nil {
			t.Fatalf("%s: expected panic, got none", name)
		}
	}()
	fn()
}

func TestCreateMandate(cur realm, t *testing.T) {
	resetState()
	id := createMandate(testPayer, testPayee, 100, 10, 3, 300)
	if id != 1 {
		t.Fatalf("expected id 1, got %d", id)
	}
	m := GetMandate(1)
	if m.Amount != 100 || m.Escrow != 300 || m.MaxPayments != 3 {
		t.Fatalf("bad mandate state: %v", m)
	}
	if !m.Active {
		t.Fatalf("mandate should be active")
	}
	if m.Payer != testPayer || m.Payee != testPayee {
		t.Fatalf("bad parties: payer %s payee %s", m.Payer.String(), m.Payee.String())
	}
	if MandateCount() != 1 {
		t.Fatalf("expected count 1, got %d", MandateCount())
	}
}

func TestCreateMandateBadInputs(cur realm, t *testing.T) {
	resetState()
	expectPanic(t, "zero amount", func() {
		createMandate(testPayer, testPayee, 0, 10, 3, 0)
	})
	expectPanic(t, "zero interval", func() {
		createMandate(testPayer, testPayee, 100, 0, 3, 300)
	})
	expectPanic(t, "zero maxPayments", func() {
		createMandate(testPayer, testPayee, 100, 10, 0, 0)
	})
	expectPanic(t, "wrong deposit", func() {
		createMandate(testPayer, testPayee, 100, 10, 3, 299)
	})
	expectPanic(t, "over deposit", func() {
		createMandate(testPayer, testPayee, 100, 10, 3, 301)
	})
}

func TestApplyPaymentFlow(cur realm, t *testing.T) {
	resetState()
	id := createMandate(testPayer, testPayee, 100, 10, 3, 300)
	due := GetMandate(id).NextDueHeight
	// Too early: must panic.
	expectPanic(t, "pay before due", func() {
		applyPayment(0, due-1)
	})
	// First payment at due height.
	applyPayment(0, due)
	m := GetMandate(id)
	if m.PaymentsMade != 1 || m.Escrow != 200 || !m.Active {
		t.Fatalf("after pay 1: %v", m)
	}
	// Second payment one interval later.
	applyPayment(0, due+10)
	m = GetMandate(id)
	if m.PaymentsMade != 2 || m.Escrow != 100 || !m.Active {
		t.Fatalf("after pay 2: %v", m)
	}
	// Third payment completes the mandate.
	applyPayment(0, due+20)
	m = GetMandate(id)
	if m.PaymentsMade != 3 || m.Escrow != 0 || m.Active {
		t.Fatalf("after pay 3: %v", m)
	}
	// Fourth payment must panic.
	expectPanic(t, "pay after complete", func() {
		applyPayment(0, due+30)
	})
}

func TestApplyCancel(cur realm, t *testing.T) {
	resetState()
	id := createMandate(testPayer, testPayee, 100, 10, 3, 300)
	applyPayment(0, GetMandate(id).NextDueHeight)
	// Non-payer cannot cancel.
	expectPanic(t, "cancel by non-payer", func() {
		applyCancel(0, testPayee)
	})
	// Payer cancels: refund is the remaining escrow (200).
	refund := applyCancel(0, testPayer)
	if refund != 200 {
		t.Fatalf("expected refund 200, got %d", refund)
	}
	m := GetMandate(id)
	if m.Active || m.Escrow != 0 {
		t.Fatalf("after cancel: %v", m)
	}
	// Cancelling again must panic.
	expectPanic(t, "cancel twice", func() {
		applyCancel(0, testPayer)
	})
}

func TestListMandates(cur realm, t *testing.T) {
	resetState()
	createMandate(testPayer, testPayee, 100, 10, 2, 200)
	createMandate(testPayer, testPayee, 50, 5, 4, 200)
	list := ListMandates()
	if len(list) != 2 {
		t.Fatalf("expected 2 mandates, got %d", len(list))
	}
	if list[0].ID != 1 || list[1].ID != 2 {
		t.Fatalf("bad ids: %d, %d", list[0].ID, list[1].ID)
	}
	// Mutating the returned slice must not touch realm state.
	list[0].Amount = 999
	if GetMandate(1).Amount != 100 {
		t.Fatalf("ListMandates leaked mutable state")
	}
}

func TestRender(cur realm, t *testing.T) {
	resetState()
	out := Render("")
	if out == "" {
		t.Fatalf("empty render")
	}
	createMandate(testPayer, testPayee, 100, 10, 2, 200)
	out = Render("")
	if !contains(out, "TavernPay") || !contains(out, "100") {
		t.Fatalf("render missing content: %s", out)
	}
}

func contains(s, sub string) bool {
	if len(sub) == 0 {
		return true
	}
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
