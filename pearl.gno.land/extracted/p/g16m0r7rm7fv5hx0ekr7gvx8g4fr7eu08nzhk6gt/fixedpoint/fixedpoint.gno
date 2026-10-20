package fixedpoint

const Scale = int64(1000000)

type Fixed struct {
	Raw int64
}

func New(whole, frac int64) Fixed {
	return Fixed{Raw: whole*Scale + frac}
}

func FromInt(i int64) Fixed {
	return Fixed{Raw: i * Scale}
}

func (f Fixed) Add(other Fixed) Fixed {
	return Fixed{Raw: f.Raw + other.Raw}
}

func (f Fixed) Sub(other Fixed) Fixed {
	return Fixed{Raw: f.Raw - other.Raw}
}

func (f Fixed) Mul(other Fixed) Fixed {
	return Fixed{Raw: (f.Raw * other.Raw) / Scale}
}

func (f Fixed) Div(other Fixed) Fixed {
	if other.Raw == 0 {
		panic("fixedpoint: division by zero")
	}
	return Fixed{Raw: (f.Raw * Scale) / other.Raw}
}

func (f Fixed) String() string {
	whole := f.Raw / Scale
	frac := f.Raw % Scale
	if frac < 0 {
		frac = -frac
	}
	fracStr := itoa(frac)
	for len(fracStr) < 6 {
		fracStr = "0" + fracStr
	}
	return itoa(whole) + "." + fracStr
}

func itoa(n int64) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	s := string(buf[i:])
	if neg {
		s = "-" + s
	}
	return s
}
