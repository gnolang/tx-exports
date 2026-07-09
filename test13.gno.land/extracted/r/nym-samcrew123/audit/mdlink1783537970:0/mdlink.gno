package mdlink

var message string

func SetMessage(cur realm, m string) {
	message = m
}

func Render(_ string) string {
	return message
}
