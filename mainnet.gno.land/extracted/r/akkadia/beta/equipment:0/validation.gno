package equipment

import "unicode/utf8"

const renderURLMaxRunes = 1024

func assertRenderURLLen(value string) {
	if utf8.RuneCountInString(value) > renderURLMaxRunes {
		panic("url exceeds max runes")
	}
}
