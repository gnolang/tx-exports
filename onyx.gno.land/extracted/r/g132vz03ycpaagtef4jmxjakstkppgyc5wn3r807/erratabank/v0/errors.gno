package erratabank

const (
	errCurrentRealm = "invalid realm context"
	errDirectCall   = "payment requires a direct user call"
	errPaymentDenom = "only ugnot is accepted"
	errPayment      = "payment must be positive"
	errRejectCoins  = "this function does not accept coins"
	errBookMissing  = "book not found"
	errErratumMiss  = "erratum not found"
	errOwnerOnly    = "book owner only"
	errPendingOnly  = "erratum must be pending"
	errClosed       = "book is closed to submissions"
	errSelfSubmit   = "book owners cannot submit to their own book"
	errDuplicate    = "original must be an earlier accepted erratum in the same book"
	errWithdraw     = "withdrawal must be positive and within available escrow"
	errOverflow     = "amount exceeds accounting limit"
)
