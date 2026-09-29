package livecheck

var n int

func Bump(cur realm) { n++ }

func Render(_ string) string { return "live" }
