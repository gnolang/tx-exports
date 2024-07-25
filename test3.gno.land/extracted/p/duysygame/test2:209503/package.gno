package test2

import (
	"regexp"
	"std"
	"strconv"
	"strings"

	"gno.land/p/demo/avl"
)

var (
	admin    std.Address = "g1ur2ja8j0g2a76s2jsqp8qh9y0g6mvkr24f34a3" // TODO: helper to change admin
	addr2Car avl.Tree                                                 // std.Address -> *Car
)

type Car struct {
	ownerAddress  std.Address
	driverAddress std.Address
	name          string
	x             int
	y             int
}

func login(driverAddress std.Address) {
	std.AssertOriginCall()
	caller := std.GetCallerAt(2)
	if caller != std.GetOrigCaller() {
		panic("should not happen") // because std.AssertOrigCall().
	}
	index, carI, ok := addr2Car.Get(caller.String())
	if ok {
		car := carI.(*Car)
		car.driverAddress = driverAddress
	} else {
		car := &Car{
			ownerAddress:  caller.String(),
			driverAddress: driverAddress,
			name:          "Car lever 1",
			number:        counter,
			x:             0,
			y:             0,
		}
		addr2User.Set(caller.String(), car)
	}
}
func Render(path string) string {
	return "Hello World!"
}
