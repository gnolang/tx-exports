package checkerr

import "errors"

type MyStruct struct {
  name string
}

func Err(path string) error {
  return errors.New("lol error")
}

func Struct() MyStruct {
  return MyStruct{
    name: "lmao"
  }
}
