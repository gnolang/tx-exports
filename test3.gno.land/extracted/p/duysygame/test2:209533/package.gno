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

func login(driverAddress std.Address) *Car{
	std.AssertOriginCall()
	caller := std.GetCallerAt(2)
	if caller != std.GetOrigCaller() {
		panic("should not happen") // because std.AssertOrigCall().
	}
	index, carI, ok := addr2Car.Get(caller.String())
	if ok {
		car := carI.(*Car)
		car.driverAddress = driverAddress
		return car
	} else {
		car := &Car{
			ownerAddress:  caller,
			driverAddress: driverAddress,
			name:          "Car lever 1",
			x:             0,
			y:             0,
		}
		addr2Car.Set(caller.String(), car)
		return car
	}
}

func up(driverAddress std.Address) {
	std.AssertOriginCall()
	assertIsDrive()
	car.y += 1

}

func down(driverAddress std.Address) {
	std.AssertOriginCall()
	assertIsDrive()
	car.y -= 1

}

func left(driverAddress std.Address) {
	std.AssertOriginCall()
	assertIsDrive()
	car.x -= 1

}

func right(driverAddress std.Address) {
	std.AssertOriginCall()
	assertIsDrive()
	car.x += 1

}

func assertIsDrive() *Car {
	caller := std.GetCallerAt(2)
	if caller != std.GetOrigCaller() {
		panic("should not happen") // because std.AssertOrigCall().
	}
	index, carI, ok := addr2Car.Get(caller.String())
	if !ok {
		panic("Please login to create new car, car not found !")
	}
	car := carI.(*Car)
	if caller != car.driverAddress {
		panic("drive not able access")
	}
	return car
}


func Render(path string) string {
	return "Hello World!"
}
