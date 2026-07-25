package core

// MaxPacketDataEventSize returns the configured packet_data event budget after
// hexAttr encoding.
//
// The budget is MaxEventAttrPairs * MaxEventAttrValueLen and is enforced only
// when SplitEventAttrs is true.
func MaxPacketDataEventSize() int {
	config := GetEventConfig()
	return int(config.MaxEventAttrPairs * config.MaxEventAttrValueLen)
}

// IsValidPacketDataSize reports whether data stays within the configured
// packet_data event budget after hexAttr encoding.
//
// It returns true when SplitEventAttrs is false because that mode intentionally
// disables packet_data size checks.
func IsValidPacketDataSize(data []byte) bool {
	if !GetEventConfig().SplitEventAttrs {
		return true
	}

	return hexAttrLen(data) <= MaxPacketDataEventSize()
}

// eventColumnPairs returns the number of attr pairs encodedEventAttrs would
// emit for data: one "<key>_size" pair plus one pair per split column.
func eventColumnPairs(data []byte) int {
	maxValueLen := int(GetEventConfig().MaxEventAttrValueLen)
	columns := (hexAttrLen(data) + maxValueLen - 1) / maxValueLen
	if columns < 1 {
		columns = 1
	}

	return 1 + columns
}

// IsValidEventSize reports whether fields, split together into one host
// event, stay within chain.Emit's 64-attr-pair ceiling. Fields within
// IsValidPacketDataSize's solo budget individually can still exceed it
// combined, so MaxEventAttrPairs also serves as the shared pair budget here.
func IsValidEventSize(fields ...[]byte) bool {
	if !GetEventConfig().SplitEventAttrs {
		return true
	}

	total := 0
	for _, data := range fields {
		total += eventColumnPairs(data)
	}

	return total <= int(GetEventConfig().MaxEventAttrPairs)
}
