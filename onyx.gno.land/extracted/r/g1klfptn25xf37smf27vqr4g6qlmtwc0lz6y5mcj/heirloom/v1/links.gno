package heirloom

import (
	"strconv"

	"gno.land/p/moul/txlink/v0"
)

func link(label, url string) string {
	return "[" + label + "](" + url + ")"
}

func backLink() string {
	return link("Back to Heirloom", webPath)
}

func willLink(id int) string {
	return link("will "+strconv.Itoa(id), WillURL(id))
}

func userLink(addr address) string {
	return link(shortAddr(addr), UserURL(addr))
}

func userPageLink(label string, addr address, list string, before int) string {
	return link(label, UserURL(addr)+"/"+list+"/"+strconv.Itoa(before))
}

func txURL(fn string, send int64, args ...string) string {
	l := txlink.Realm(pkgPath).NewLink(fn).AddArgs(args...)
	if send > 0 {
		l = l.SetSend(strconv.FormatInt(send, 10) + gnot)
	}
	return l.URL()
}
