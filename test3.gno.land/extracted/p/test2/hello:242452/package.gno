package hello

var {
  hello string
}

func SetHello(msg string){
  hello = msg
}

func GetHello() string {
  return hello
}
