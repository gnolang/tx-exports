package helping

var (  
  helping string
)
 
 func SetHelping(msg string) {
  helping=msg
}

func GetHelping() string {
  return helping
}