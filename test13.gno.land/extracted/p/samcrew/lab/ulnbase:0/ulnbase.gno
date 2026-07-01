package ulnbase

import (
	"gno.land/p/samcrew/deps/onbloc/json"
	"gno.land/p/nt/ufmt/v0"
)

// XXX: not sure having the counts will be an opti on gno, need to benchmark

type UlnConfig struct {
	Confirmations        uint64
	RequiredDVNCount     uint8
	OptionalDVNCount     uint8
	OptionalDVNThreshold uint8
	RequiredDVNs         []address
	OptionalDVNs         []address
}

type SetDefaultUlnConfigParam struct {
	Eid    uint32
	Config *UlnConfig
}

// Error types
var (
	ErrULNUnsorted                    = "LZ_ULN_Unsorted"
	ErrULNInvalidRequiredDVNCount     = "LZ_ULN_InvalidRequiredDVNCount"
	ErrULNInvalidOptionalDVNCount     = "LZ_ULN_InvalidOptionalDVNCount"
	ErrULNAtLeastOneDVN               = "LZ_ULN_AtLeastOneDVN"
	ErrULNInvalidOptionalDVNThreshold = "LZ_ULN_InvalidOptionalDVNThreshold"
	ErrULNInvalidConfirmations        = "LZ_ULN_InvalidConfirmations"
	ErrULNUnsupportedEid              = "LZ_ULN_UnsupportedEid"
)

// Constants
var (
	DEFAULT_CONFIG    = address("")
	DEFAULT           = uint8(0)
	NIL_DVN_COUNT     = ^uint8(0)  // max uint8
	NIL_CONFIRMATIONS = ^uint64(0) // max uint64
	MAX_COUNT         = (^uint8(0) - 1) / 2
)

type UlnBase struct {
	ulnConfigs configStore
}

func (u *UlnBase) SetDefaultUlnConfigs(params []SetDefaultUlnConfigParam) {
	for _, param := range params {
		// Must not use NIL values
		if param.Config.RequiredDVNCount == NIL_DVN_COUNT {
			panic(ErrULNInvalidRequiredDVNCount)
		}
		if param.Config.OptionalDVNCount == NIL_DVN_COUNT {
			panic(ErrULNInvalidOptionalDVNCount)
		}
		if param.Config.Confirmations == NIL_CONFIRMATIONS {
			panic(ErrULNInvalidConfirmations)
		}

		// Must have at least one DVN
		assertAtLeastOneDVN(param.Config)

		u.setConfig(DEFAULT_CONFIG, param.Eid, param.Config)
	}

	// Emit event
	// chain.Emit(ufmt.Sprintf("DefaultUlnConfigsSet(%v)", params))
}

func (u *UlnBase) GetUlnConfig(oapp address, remoteEid uint32) *UlnConfig {
	defaultConfig, _ := u.ulnConfigs.get(DEFAULT_CONFIG, remoteEid)
	customConfig, hasCustom := u.ulnConfigs.get(oapp, remoteEid)

	rtnConfig := *defaultConfig

	// Handle confirmations
	if hasCustom && customConfig.Confirmations == uint64(DEFAULT) {
		rtnConfig.Confirmations = defaultConfig.Confirmations
	} else if hasCustom && customConfig.Confirmations != NIL_CONFIRMATIONS {
		rtnConfig.Confirmations = customConfig.Confirmations
	}

	// Handle required DVNs
	if hasCustom && customConfig.RequiredDVNCount == DEFAULT {
		if defaultConfig.RequiredDVNCount > 0 {
			rtnConfig.RequiredDVNs = defaultConfig.RequiredDVNs
			rtnConfig.RequiredDVNCount = defaultConfig.RequiredDVNCount
		}
	} else if hasCustom && customConfig.RequiredDVNCount != NIL_DVN_COUNT {
		rtnConfig.RequiredDVNs = customConfig.RequiredDVNs
		rtnConfig.RequiredDVNCount = customConfig.RequiredDVNCount
	}

	// Handle optional DVNs
	if hasCustom && customConfig.OptionalDVNCount == DEFAULT {
		if defaultConfig.OptionalDVNCount > 0 {
			rtnConfig.OptionalDVNs = defaultConfig.OptionalDVNs
			rtnConfig.OptionalDVNCount = defaultConfig.OptionalDVNCount
			rtnConfig.OptionalDVNThreshold = defaultConfig.OptionalDVNThreshold
		}
	} else if hasCustom && customConfig.OptionalDVNCount != NIL_DVN_COUNT {
		rtnConfig.OptionalDVNs = customConfig.OptionalDVNs
		rtnConfig.OptionalDVNCount = customConfig.OptionalDVNCount
		rtnConfig.OptionalDVNThreshold = customConfig.OptionalDVNThreshold
	}

	// The final value must have at least one DVN
	assertAtLeastOneDVN(&rtnConfig)

	return &rtnConfig
}

func (u *UlnBase) GetAppUlnConfig(oapp address, remoteEid uint32) *UlnConfig {
	val, _ := u.ulnConfigs.get(oapp, remoteEid)
	return val
}

func (u *UlnBase) SetUlnConfig(remoteEid uint32, oapp address, param *UlnConfig) {
	u.setConfig(oapp, remoteEid, param)

	// Get ULN config again as a catch all to ensure the config is valid
	u.GetUlnConfig(oapp, remoteEid)

	// Emit event
	// chain.Emit(ufmt.Sprintf("UlnConfigSet(%s, %d, %v)", oapp, remoteEid, param))
}

func (u *UlnBase) IsSupportedEid(remoteEid uint32) bool {
	defaultConfig, exists := u.ulnConfigs.get(DEFAULT_CONFIG, remoteEid)
	if !exists {
		return false
	}
	return defaultConfig.RequiredDVNCount > 0 || defaultConfig.OptionalDVNThreshold > 0
}

func (u *UlnBase) AssertSupportedEid(remoteEid uint32) {
	if !u.IsSupportedEid(remoteEid) {
		panic(ufmt.Sprintf("%s: %d", ErrULNUnsupportedEid, remoteEid))
	}
}

func assertAtLeastOneDVN(config *UlnConfig) {
	if config.RequiredDVNCount == 0 && config.OptionalDVNThreshold == 0 {
		panic(ErrULNAtLeastOneDVN)
	}
}

func (u *UlnBase) setConfig(oapp address, eid uint32, param *UlnConfig) {
	// Required DVNs validation
	if param.RequiredDVNCount == NIL_DVN_COUNT || param.RequiredDVNCount == DEFAULT {
		if len(param.RequiredDVNs) != 0 {
			panic(ErrULNInvalidRequiredDVNCount)
		}
	} else {
		if len(param.RequiredDVNs) != int(param.RequiredDVNCount) || param.RequiredDVNCount > MAX_COUNT {
			panic(ErrULNInvalidRequiredDVNCount)
		}
		u.assertNoDuplicates(param.RequiredDVNs)
	}

	// Optional DVNs validation
	if param.OptionalDVNCount == NIL_DVN_COUNT || param.OptionalDVNCount == DEFAULT {
		if len(param.OptionalDVNs) != 0 {
			panic(ErrULNInvalidOptionalDVNCount)
		}
		if param.OptionalDVNThreshold != 0 {
			panic(ErrULNInvalidOptionalDVNThreshold)
		}
	} else {
		if len(param.OptionalDVNs) != int(param.OptionalDVNCount) || param.OptionalDVNCount > MAX_COUNT {
			panic(ErrULNInvalidOptionalDVNCount)
		}
		if param.OptionalDVNThreshold == 0 || param.OptionalDVNThreshold > param.OptionalDVNCount {
			panic(ErrULNInvalidOptionalDVNThreshold)
		}
		u.assertNoDuplicates(param.OptionalDVNs)
	}
	// Store the config
	u.ulnConfigs.set(oapp, eid, param)
}

func (u *UlnBase) assertNoDuplicates(dvns []address) {
	if len(dvns) == 0 {
		return
	}

	lastDVN := dvns[0]
	for i := 1; i < len(dvns); i++ {
		if dvns[i] <= lastDVN {
			panic(ErrULNUnsorted)
		}
		lastDVN = dvns[i]
	}
}

// Render function for the contract
func (u *UlnBase) Render(path string) string {
	return "XXX: TODO"
}

func (ucfg *UlnConfig) MarshalJSONString() string {
	if ucfg == nil {
		return "{}"
	}
	node := json.ObjectNode("", map[string]*json.Node{
		"confirmations":        json.NumberNode("", float64(ucfg.Confirmations)),
		"requiredDVNCount":     json.NumberNode("", float64(ucfg.RequiredDVNCount)),
		"optionalDVNCount":     json.NumberNode("", float64(ucfg.OptionalDVNCount)),
		"optionalDVNThreshold": json.NumberNode("", float64(ucfg.OptionalDVNThreshold)),
		"requiredDVNs":         json.ArrayNode("", addressSliceToJSON(ucfg.RequiredDVNs)),
		"optionalDVNs":         json.ArrayNode("", addressSliceToJSON(ucfg.OptionalDVNs)),
	})
	res, err := json.Marshal(node)
	if err != nil {
		panic(err)
	}
	return string(res)
}

func addressSliceToJSON(s []address) []*json.Node {
	res := make([]*json.Node, 0, len(s))
	for _, elem := range s {
		res = append(res, json.StringNode("", elem.String()))
	}
	return res
}
