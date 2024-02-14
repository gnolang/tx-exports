// first.gno

package first

import "gno.land/p/demo/avl"

var myVar = 1

const myConst = 10

var initlVar int

func init() {
	initlVar = 1000
}

func GetInitValue() int {
	return initlVar
}

func get() int {
	return myVar
}

func Get() int {
	return myVar
}

func Inc() int {
	myVar += 1
	return myVar
}

func IncByInput(inc int) int {
	myVar += inc
	return myVar
}

func Dec() {
	myVar -= 1
}

func ImpossibleInc() {
	myConst += 1
}