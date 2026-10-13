package bolo

import "strconv"

// The events Bolo emits (API §6), for the web app's indexer. Their attributes are
// strings.
const (
	evCampaignCreated     = "CampaignCreated"
	evBondPosted          = "BondPosted"
	evBondReleased        = "BondReleased"
	evDonated             = "Donated"
	evWithdrawn           = "Withdrawn"
	evRefunded            = "Refunded"
	evUpdatePosted        = "UpdatePosted"
	evClosed              = "Closed"
	evSettled             = "Settled"
	evDelisted            = "Delisted"
	evRelisted            = "Relisted"
	evNoticeSet           = "NoticeSet"
	evStraysSwept         = "StraysSwept"
	evImageHidden         = "ImageHidden"
	evMessageHidden       = "MessageHidden"
	evParamsChanged       = "ParamsChanged"
	evAdminProposed       = "AdminProposed"
	evAdminChanged        = "AdminChanged"
	evPaused              = "Paused"
	evUnpaused            = "Unpaused"
	evTipRecipientChanged = "TipRecipientChanged"
	evMinDonationChanged  = "MinDonationChanged"
	evPresetsChanged      = "PresetsChanged"
	evEscrowCapChanged    = "EscrowCapChanged"
	evCategoryAdded       = "CategoryAdded"
	evSunset              = "Sunset"
)

// itoa formats an amount, a timestamp or a sequence number as an attribute.
func itoa(n int64) string { return strconv.FormatInt(n, 10) }
