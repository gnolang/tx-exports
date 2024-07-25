package person

import "strconv"

var (
    myName = "John Smith"
    myAge = 42
    myAddress = "123 Main Street"
)

func Render(path string) string {
    // You can also use "gno.land/p/demo/ufmt" package, check `ufmt.Sprintf()`
    return "My name is: " + myName + "my Age is: " + strconv.Itoa(myAge) + "& my Address is: " + myAddress
}

func updateAddress(NewAddress string) string {
    myAddress = NewAddress
    return "Your address has been updated"
}