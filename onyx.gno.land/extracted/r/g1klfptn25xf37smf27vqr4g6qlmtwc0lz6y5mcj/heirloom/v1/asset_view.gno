package heirloom

import (
	"strconv"
	"strings"

	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/r/nt/grc20reg/v0"
)

type assetInfo struct {
	label    string
	symbol   string
	unit     string
	decimals int
}

type assetInfos map[string]assetInfo

func describe(asset string) assetInfo {
	if asset == gnot {
		return assetInfo{label: "GNOT", symbol: "GNOT", unit: gnot, decimals: 6}
	}
	tok := grc20reg.MustGet(asset)
	return assetInfo{
		label:    sanitize.TableCell(tok.GetName()) + " (`" + asset + "`)",
		symbol:   sanitize.TableCell(tok.GetSymbol()),
		unit:     "units",
		decimals: tok.GetDecimals(),
	}
}

func describeAll(assets []string) assetInfos {
	infos := assetInfos{}
	for _, asset := range assets {
		infos[asset] = describe(asset)
	}
	return infos
}

func (a assetInfo) unitNote() string {
	if a.decimals == 0 {
		return ""
	}
	return "1 " + a.symbol + " = 1" + strings.Repeat("0", a.decimals) + " " + a.unit
}

func (a assetInfo) amount(units int64) string {
	s := strconv.FormatInt(units, 10)
	if a.decimals > 0 {
		if len(s) <= a.decimals {
			s = strings.Repeat("0", a.decimals-len(s)+1) + s
		}
		whole, frac := s[:len(s)-a.decimals], strings.TrimRight(s[len(s)-a.decimals:], "0")
		if frac != "" {
			whole += "." + frac
		}
		s = whole
	}
	return strings.TrimSpace(s + " " + a.symbol)
}
