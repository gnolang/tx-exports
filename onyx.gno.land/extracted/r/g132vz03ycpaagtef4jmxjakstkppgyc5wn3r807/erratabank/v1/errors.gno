package erratabank

const (
	errCurrentRealm          = "invalid realm context"
	errDirectCall            = "payment requires a direct user call"
	errPaymentDenom          = "only ugnot is accepted"
	errPayment               = "payment must be positive"
	errRejectCoins           = "this function does not accept coins"
	errBookMissing           = "book not found"
	errErratumMiss           = "erratum not found"
	errOwnerOnly             = "book owner only"
	errPendingOnly           = "erratum must be pending"
	errClosed                = "book is closed to submissions"
	errEarlierPending        = "resolve the earlier pending report at this location first"
	errDuplicate             = "original must be an earlier pending or accepted erratum in the same book"
	errWithdraw              = "withdrawal must be positive and within unreserved owner funds"
	errClosedAccept          = "closed books cannot accept reports"
	errClosedSponsor         = "closed books cannot receive sponsor deposits"
	errSponsorRefundsPending = "refund remaining sponsor funds before reopening"
	errRefundUnavailable     = "sponsor refunds require a closed book with no unpaid rewards"
	errNoSponsorFunds        = "no sponsor funds to refund"
	errOverflow              = "amount exceeds accounting limit"
	errIDLimit               = "identifier limit reached"
)
