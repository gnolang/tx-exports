package person

var (
    myName = "John Smith"
    myAge = 42
    myAddress = "123 Main Street"
)

function Render(path string) string {
    return "My name is: " + myName "my Age is: " + myAge "& my Address is: " myAddress
}

function UpdateAdddress(NewAddress string) string {
    myAddress = NewAddress
    return "Your address has been updated"
}