package doorbell_202501082320
import "gno.land/p/demo/ufmt"
var counter int
func Ring() {
    // Increments the counter by one
    counter++
}
func Reset() {
    // Resets the counter to zero
    counter = 0
}
func Render() string {
    // Provides a human-readable state of the realm
    return ufmt.Sprintf("The doorbell has been rung %d times.", counter)
}