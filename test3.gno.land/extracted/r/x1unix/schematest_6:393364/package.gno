package schematest_6

import (
  "gno.land/p/demo/ufmt"
  "strconv"
  "strings"
)

func Render(path string) string {
  return "Hello World!"
}

// func TestSpread(a string, b ...string) string {
//   sb := &strings.Builder{}
//   sb.WriteString(a)
//   for _, v := range b {
//     sb.WriteString(", ")
//     sb.WriteString(v)
//   }

//   return sb.String()
// }

func TestByte(b byte) string {
  return strconv.FormatUint(uint64(uint8(b)), 10)
}

func TestB(b bool) string {
  return ufmt.Sprintf("%t", b)
}

func TestS(s string) string {
  return s
}

func TestI(i int) string {
  return strconv.Itoa(int(i))
}

func TestI8(i int8) string {
  return strconv.Itoa(int(i))
}

func TestI16(i int16) string {
  return strconv.Itoa(int(i))
}

func TestI32(i int32) string {
  return strconv.Itoa(int(i))
}

func TestI64(i int64) string {
  return strconv.Itoa(int(i))
}

func TestU(i uint) string {
  return strconv.FormatUint(uint64(i), 10)
}

func TestU8(i uint8) string {
  return strconv.FormatUint(uint64(i), 10)
}

func TestU16(i uint16) string {
  return strconv.FormatUint(uint64(i), 10)
}

func TestU32(i uint32) string {
  return strconv.FormatUint(uint64(i), 10)
}

func TestU64(i uint64) string {
  return strconv.FormatUint(i, 10)
}

func TestF32(f float32) string {
  mantissa := int(f)
  expo := (f - float32(int(f))) * 10000
  if expo <= -1 {
    expo *= -1
  }

  return ufmt.Sprintf("%d.%d", mantissa, int(expo))
}

func TestF64(f float64) string {
  mantissa := int(f)
  expo := (f - float64(int(f))) * 10000
  if expo <= -1 {
    expo *= -1
  }

  return ufmt.Sprintf("%d.%d", mantissa, int(expo))
}

func TestVecU8(vals []uint8) string {
  if len(vals) == 0 {
    return "<empty>"
  }

  sb := &strings.Builder{}
  for i, v := range vals {
    if i != 0 {
      sb.WriteString(", ")
    }
    sb.WriteString(strconv.FormatUint(v, 10))
  }
  
  return sb.String()
}