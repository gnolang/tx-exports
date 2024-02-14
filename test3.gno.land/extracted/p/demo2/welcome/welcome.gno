// welcome.gno

package welcome


var MsgOfPkg = "this is a public variable"
var msgOfPkg = "this is a private variable"

func GetPrivVar() string {
	return msgOfPkg
}

func Gnome(name string) string {
	return "greetings " + name + ", welcome to the gnoland"
}