package gamedemo

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
	callerAddressString := caller.String();
	carI, ok := addr2Car.Get(callerAddressString)
	if ok {
		car := carI.(*Car)
		car.driverAddress += driverAddress
	} else {
		car := &Car{
			ownerAddress:  caller.String(),
			driverAddress: driverAddress,
			name:          "Car lever 1",
			number:        counter,
			x:             0,
			y:             0,
		}
		addr2User.Set(callerAddressString, car)
	}
}
func Render(path string) string {
	return "Hello World!"
}
