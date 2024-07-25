package helping

var (  
  helping string
)
 
// setters -> tx (spend money, GNOT; ETH)
func SetHelping(msg string) {
  helping = msg
}

// getter -> query (read-only) = FREE
func GetHelping() string {
  return helping
}
