package counter
import "strconv"
var count int
func increment(_ realm) int {
  count++
  return count
}

  func Render(path string) string {
    return "count:" + strconv.Itoa(count)
}