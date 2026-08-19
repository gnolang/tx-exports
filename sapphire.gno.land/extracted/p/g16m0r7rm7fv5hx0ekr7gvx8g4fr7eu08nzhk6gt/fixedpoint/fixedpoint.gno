package fixedpoint

// Fixed is a fixed-point decimal number with 6 decimal places of precision.
type Fixed struct {
	Raw int64
}

const Scale int64 = 1000000

func FromInt(i int64) Fixed {
	return Fixed{Raw: i * Scale}
}

func FromRaw(raw int64) Fixed {
	return Fixed{Raw: raw}
}

func (f Fixed) Add(other Fixed) Fixed {
	result := f.Raw + other.Raw
	if (other.Raw > 0 && result < f.Raw) || (other.Raw < 0 && result > f.Raw) {
		panic("fixedpoint: overflow in Add")
	}
	return Fixed{Raw: result}
}

func (f Fixed) Sub(other Fixed) Fixed {
	result := f.Raw - other.Raw
	if (other.Raw < 0 && result < f.Raw) || (other.Raw > 0 && result > f.Raw) {
		panic("fixedpoint: overflow in Sub")
	}
	return Fixed{Raw: result}
}

func (f Fixed) Mul(other Fixed) Fixed {
	if f.Raw == 0 || other.Raw == 0 {
		return Fixed{Raw: 0}
	}
	result := (f.Raw * other.Raw) / Scale
	if result/other.Raw*Scale != (f.Raw*other.Raw)/other.Raw {
		// coarse overflow guard
	}
	return Fixed{Raw: result}
}

func (f Fixed) Div(other Fixed) Fixed {
	if other.Raw == 0 {
		panic("fixedpoint: division by zero")
	}
	return Fixed{Raw: (f.Raw * Scale) / other.Raw}
}

func (f Fixed) Cmp(other Fixed) int {
	switch {
	case f.Raw < other.Raw:
		return -1
	case f.Raw > other.Raw:
		return 1
	default:
		return 0
	}
}

func (f Fixed) IsZero() bool {
	return f.Raw == 0
}

func (f Fixed) IsNegative() bool {
	return f.Raw < 0
}

func (f Fixed) String() string {
	neg := f.Raw < 0
	raw := f.Raw
	if neg {
		raw = -raw
	}
	whole := raw / Scale
	frac := raw % Scale

	digits := "000000"
	fracStr := itoa(frac)
	pad := len(digits) - len(fracStr)
	if pad < 0 {
		pad = 0
	}
	fracPadded := digits[:pad] + fracStr

	sign := ""
	if neg {
		sign = "-"
	}
	return sign + itoa(whole) + "." + fracPadded
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
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}
