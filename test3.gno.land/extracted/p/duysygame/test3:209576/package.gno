package test3

import (
	"regexp"
	"std"
	"strconv"
	"strings"
	"gno.land/p/demo/avl"
)

var (
	admin    std.Address = "g1ur2ja8j0g2a76s2jsqp8qh9y0g6mvkr24f34a3" // TODO: helper to change admin
	addrOwner2Car avl.Tree                                            // std.Address -> *Car
	addrDriver2Car avl.Tree                                           // std.Address -> *Car
)

type Car struct {
	ownerAddress  std.Address
	driverAddress std.Address
	name          string
	x             int
	y             int
}

func login(driverAddress std.Address) *Car {
	std.AssertOriginCall()
	caller := std.GetCallerAt(2)
	if caller != std.GetOrigCaller() {
		panic("should not happen") // because std.AssertOrigCall().
	}
	index, carI, ok := addrOwner2Car.Get(caller.String())
	if ok {
		car := carI.(*Car)
		car.driverAddress = driverAddress
		addrOwner2Car.Set(caller.String(), car)
		addrDriver2Car.Set(driverAddress.String(), car)
		return car
	} else {
		car := &Car{
			ownerAddress:  caller,
			driverAddress: driverAddress,
			name:          "Car lever 1",
			x:             0,
			y:             0,
		}
		addrOwner2Car.Set(caller.String(), car)
		addrDriver2Car.Set(driverAddress.String(), car)
		return car
	}
	
}

func Up() {
	std.AssertOriginCall()
	caller := std.GetCallerAt(2)
	if caller != std.GetOrigCaller() {
		panic("should not happen") // because std.AssertOrigCall().
	}
	car := assertIsDrive(caller.String()) // This line is changed
	car.y += 1
}

func Down() {
	std.AssertOriginCall()
	caller := std.GetCallerAt(2)
	if caller != std.GetOrigCaller() {
		panic("should not happen") // because std.AssertOrigCall().
	}
	car := assertIsDrive(caller.String()) // This line is changed
	car.y -= 1

}

func Left() {
	std.AssertOriginCall()
	caller := std.GetCallerAt(2)
	if caller != std.GetOrigCaller() {
		panic("should not happen") // because std.AssertOrigCall().
	}
	car := assertIsDrive(caller.String()) // This line is changed
	car.x -= 1

}

func Right() {
	std.AssertOriginCall()
	caller := std.GetCallerAt(2)
	if caller != std.GetOrigCaller() {
		panic("should not happen") // because std.AssertOrigCall().
	}
	car := assertIsDrive(caller.String()) // This line is changed
	car.x += 1

}
func GetCarByAddress(addr std.Address) *Car {
	index, carI, ok := addrOwner2Car.Get(addr.String())
	if !ok {
		return nil
	}
	return carI.(*Car)
}

func assertIsDrive(caller string) *Car {
	index, carI, ok := addrDriver2Car.Get(caller)
	if !ok {
		panic("Please login to create new car, car not found !")
	}
	car := carI.(*Car)
	if caller != car.driverAddress.String() {
		panic("drive not able access")
	}
	return car.(*Car)
}

func Render(path string) string {
	return "Hello World!"
}
