package shop

import "strconv"

// InfoJSON is the collection header. ready is false until Init.
func InfoJSON() string {
	if !ready {
		return `{"ready":false}`
	}
	return `{"ready":true,"name":` + quote(token.GetName()) +
		`,"symbol":` + quote(token.GetSymbol()) +
		`,"creator":` + quote(creator.String()) +
		`,"admins":` + adminsJSON() +
		`,"supply":` + i64(token.TotalSupply()) +
		`,"listings":` + strconv.Itoa(listings.Size()) + `}`
}

func adminsJSON() string {
	parts := make([]string, 0)
	admins.IterateByOffset(0, pageMax, func(key string, value any) bool {
		parts = append(parts, quote(key))
		return false
	})
	return "[" + join(parts) + "]"
}

// ListingsJSON returns one page of listings, oldest key first.
func ListingsJSON(offset, limit int) string {
	if !ready {
		return "[]"
	}
	offset, limit = page(offset, limit)
	parts := make([]string, 0)
	listings.IterateByOffset(offset, limit, func(key string, value any) bool {
		parts = append(parts, lotJSON(key, value.(listing)))
		return false
	})
	return "[" + join(parts) + "]"
}

// ListingJSON returns one listing or "null".
func ListingJSON(tid string) string {
	if !ready {
		return "null"
	}
	id := parseTid(tid)
	got := listings.Get(string(id))
	if got == nil {
		return "null"
	}
	return lotJSON(string(id), got.(listing))
}

// TokenJSON returns one token, listed or not.
func TokenJSON(tid string) string {
	if !ready {
		return "null"
	}
	id := parseTid(tid)
	owner := ownerOf(id)
	name, image := metaNameImage(id)
	body := `{"tid":` + quote(string(id)) +
		`,"owner":` + quote(owner.String()) +
		`,"name":` + quote(name) +
		`,"image":` + quote(image)
	got := listings.Get(string(id))
	if got == nil {
		return body + `,"listed":false}`
	}
	lot := got.(listing)
	return body + `,"listed":true,"seller":` + quote(lot.Seller.String()) +
		`,"price":` + i64(lot.Price) +
		`,"live":` + boolJSON(owner == lot.Seller) + `}`
}

// TokensJSON lists tokens owned by owner.
func TokensJSON(owner address, offset, limit int) string {
	if !ready {
		return "[]"
	}
	if !owner.IsValid() {
		panic("market: owner")
	}
	offset, limit = page(offset, limit)
	balance, err := token.BalanceOf(owner)
	if err != nil {
		panic("market: balance")
	}
	parts := make([]string, 0)
	end := int64(offset + limit)
	for i := int64(offset); i < balance && i < end; i++ {
		id, err := enumView.TokenOfOwnerByIndex(owner, i)
		if err != nil {
			panic("market: index")
		}
		name, image := metaNameImage(id)
		item := `{"tid":` + quote(string(id)) + `,"name":` + quote(name) + `,"image":` + quote(image)
		got := listings.Get(string(id))
		if got == nil {
			item += `,"listed":false}`
		} else {
			lot := got.(listing)
			item += `,"listed":true,"price":` + i64(lot.Price) + `}`
		}
		parts = append(parts, item)
	}
	return "[" + join(parts) + "]"
}

// SalesJSON returns the newest sales first.
func SalesJSON(offset, limit int) string {
	if !ready {
		return "[]"
	}
	offset, limit = page(offset, limit)
	n := saleN
	if n > saleCap {
		n = saleCap
	}
	parts := make([]string, 0)
	for i := offset; i < offset+limit && i < n; i++ {
		// i = 0 is the newest stored sale.
		idx := saleN - 1 - i
		s := sales[idx%saleCap]
		parts = append(parts, `{"tid":`+quote(s.Tid)+
			`,"name":`+quote(s.Name)+
			`,"seller":`+quote(s.Seller.String())+
			`,"buyer":`+quote(s.Buyer.String())+
			`,"price":`+i64(s.Price)+`}`)
	}
	return "[" + join(parts) + "]"
}

func lotJSON(tid string, lot listing) string {
	id := parseTid(tid)
	owner := ownerOf(id)
	name, image := metaNameImage(id)
	return `{"tid":` + quote(tid) +
		`,"seller":` + quote(lot.Seller.String()) +
		`,"owner":` + quote(owner.String()) +
		`,"price":` + i64(lot.Price) +
		`,"name":` + quote(name) +
		`,"image":` + quote(image) +
		`,"live":` + boolJSON(owner == lot.Seller) + `}`
}

func boolJSON(v bool) string {
	if v {
		return "true"
	}
	return "false"
}

func join(parts []string) string {
	out := ""
	for i, p := range parts {
		if i > 0 {
			out += ","
		}
		out += p
	}
	return out
}

func Render(path string) string {
	if path != "" {
		return "404\n"
	}
	if !ready {
		return "# market\n\ncall Init first\n"
	}
	return "# " + token.GetName() + " ($" + token.GetSymbol() + ")\n\n" +
		"* creator: " + creator.String() + "\n" +
		"* supply: " + i64(token.TotalSupply()) + "\n" +
		"* listings: " + strconv.Itoa(listings.Size()) + "\n"
}
