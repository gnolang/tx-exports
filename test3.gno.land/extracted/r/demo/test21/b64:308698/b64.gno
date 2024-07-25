package b64

import (
	"encoding/base64"
)

func EncodeMe(
	str string,
) string {
	encoded := base64.StdEncoding.EncodeToString([]byte(str))
	return encoded
}