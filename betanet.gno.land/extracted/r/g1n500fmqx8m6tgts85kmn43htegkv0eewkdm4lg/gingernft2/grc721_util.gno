package gingernft

var zeroAddress = address("")

func isValidAddress(addr address) error {
	if !addr.IsValid() {
		return ErrInvalidAddress
	}
	return nil
}

func emit(event any) {
	
}
