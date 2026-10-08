package tokens

import (
	"strconv"
	"strings"

	"gno.land/p/samcrew/launchpad/meta/v1"
	sm "gno.land/p/samcrew/launchpad/safemath/v1"
)

// int64 amounts and versions are decimal strings so JSON clients cannot round
// a valid value above JavaScript's exact integer range.
func infoJSON(e *entry) string {
	i := e.info
	return "{" +
		`"id":` + meta.JSONString(i.ID) +
		`,"registryKey":` + meta.JSONString(i.RegistryKey) +
		`,"grc20Id":` + meta.JSONString(i.GRC20ID) +
		`,"issuer":` + meta.JSONString(i.Issuer.String()) +
		`,"creator":` + meta.JSONString(i.Creator.String()) +
		`,"mode":` + meta.JSONString(i.Mode) +
		`,"name":` + meta.JSONString(i.Name) +
		`,"ticker":` + meta.JSONString(i.Ticker) +
		`,"decimals":` + strconv.Itoa(i.Decimals) +
		`,"initialSupply":` + meta.JSONString(strconv.FormatInt(i.InitialSupply, 10)) +
		`,"maxSupply":` + meta.JSONString(strconv.FormatInt(i.MaxSupply, 10)) +
		`,"totalSupply":` + meta.JSONString(strconv.FormatInt(e.token.TotalSupply(), 10)) +
		`,"configVersion":` + meta.JSONString(strconv.FormatInt(i.ConfigVersion, 10)) +
		`,"currencyKey":` + meta.JSONString(i.CurrencyKey) +
		`,"description":` + meta.JSONString(i.Metadata.Description) +
		`,"image":` + meta.JSONString(i.Metadata.Image) +
		`,"website":` + meta.JSONString(i.Metadata.Website) +
		`,"xHandle":` + meta.JSONString(i.Metadata.XHandle) +
		`,"telegram":` + meta.JSONString(i.Metadata.Telegram) +
		`,"metadataFrozen":` + strconv.FormatBool(i.MetadataFrozen) +
		`,"mintAuthority":` + meta.JSONString(i.MintAuthority.String()) +
		`,"pendingMintAuthority":` + meta.JSONString(i.PendingMintAuth.String()) +
		`,"mintRenounced":` + strconv.FormatBool(i.MintRenounced) + "}"
}

func TokenJSON(id string) string { return infoJSON(mustEntry(id)) }

// ListTokensJSON returns a zero-based page; page size is strictly 1..100.
func ListTokensJSON(page, size int64) string {
	if page < 0 || size < 1 || size > 100 {
		panic("launchpad/tokens: invalid page")
	}
	offset := sm.Mul(page, size)
	if offset >= Count() {
		return "[]"
	}
	end := offset + size
	if end > Count() {
		end = Count()
	}
	var b strings.Builder
	b.WriteByte('[')
	for i := offset; i < end; i++ {
		if i > offset {
			b.WriteByte(',')
		}
		// Entry i of the list is the token created (i+1)th.
		b.WriteString(infoJSON(mustEntry("T" + strconv.FormatInt(i+1, 10))))
	}
	b.WriteByte(']')
	return b.String()
}
