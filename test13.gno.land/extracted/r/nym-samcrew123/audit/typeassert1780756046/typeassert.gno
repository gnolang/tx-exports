package typeassert

var i interface{} = nil

func Assert() {
	_ = i.(*int)
}
