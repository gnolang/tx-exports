package nisse

import "strconv"

// companions etc

type Asset struct {
	ID           uint64
	Kind         string
	Subtype      string
	Code         string
	DisplayName  string
	OwnerPlayer  string
	Status       string
	CreatedTurn  uint64
	LastKnownPos Position
}

var assets map[uint64]*Asset
var assetKindCounters map[string]uint64
var nextAssetID uint64

func init() {
	assets = make(map[uint64]*Asset)
	assetKindCounters = make(map[string]uint64)
	nextAssetID = 1
}

func assetLabel(kind string, subtype string) string {
	if cleanName(subtype) != "" {
		return slugToken(subtype)
	}
	return slugToken(kind)
}

func slugToken(value string) string {
	out := ""
	dashPending := false
	for i := 0; i < len(value); i++ {
		ch := value[i]
		if ch >= 'A' && ch <= 'Z' {
			ch = ch + ('a' - 'A')
		}
		if (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') {
			if dashPending && len(out) > 0 {
				out += "-"
			}
			out += string(ch)
			dashPending = false
			continue
		}
		dashPending = len(out) > 0
	}
	if out == "" {
		return "asset"
	}
	return out
}

func createAsset(kind string, subtype string, displayName string, ownerPlayer string, createdTurn uint64, pos Position) Asset {
	id := nextAssetID
	nextAssetID++

	label := assetLabel(kind, subtype)
	assetKindCounters[label]++
	code := label + "-" + strconv.Itoa(int(assetKindCounters[label]))
	asset := Asset{
		ID:           id,
		Kind:         slugToken(kind),
		Subtype:      slugToken(subtype),
		Code:         code,
		DisplayName:  cleanName(displayName),
		OwnerPlayer:  ownerPlayer,
		Status:       "held",
		CreatedTurn:  createdTurn,
		LastKnownPos: pos,
	}
	assets[id] = &asset
	return asset
}
