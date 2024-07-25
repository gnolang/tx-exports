package person

// Importing `strconv` to be able to cast the age to string so it can be concatenated
import "strconv"

var (
    myName = "John Smith"
    myAge = 42
    myAddress = "123 Main Street"
)

func Render(path string) string {
    // You could also use "gno.land/p/demo/ufmt" package, check `ufmt.Sprintf()`
    // See: https://test3.gno.land/p/demo/ufmt/ufmt.gno
    // It works like standard Go's "Sprintf" but it only support "%s" and "%d" it think
    return "My name is: " + myName + "my Age is: " + strconv.Itoa(myAge) + "& my Address is: " + myAddress
}

func updateAddress(NewAddress string) string {
    myAddress = NewAddress
    return "Your address has been updated"
}