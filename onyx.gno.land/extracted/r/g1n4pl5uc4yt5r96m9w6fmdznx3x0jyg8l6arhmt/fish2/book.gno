package fish2

import (
	"chain"
	"strconv"
)

func List(cur realm, id int, priceUgnot int64) {
	caller := requireUser(cur)
	if priceUgnot <= 0 || priceUgnot > maxPrice {
		panic("fish: price")
	}
	takeExact(0)
	body := must(id)
	if body.owner != caller {
		panic("fish: owner")
	}
	guardMovable(body)
	if body.mustHeal {
		panic("fish: heal")
	}
	moveToken(caller, caller, self, id)
	body.listed = true
	body.seller = caller
	body.price = priceUgnot
	body.owner = self
	chain.Emit("List", "id", strconv.Itoa(id), "seller", caller.String(), "price", strconv.FormatInt(priceUgnot, 10))
}

func UpdatePrice(cur realm, id int, priceUgnot int64) {
	caller := requireUser(cur)
	if priceUgnot <= 0 || priceUgnot > maxPrice {
		panic("fish: price")
	}
	takeExact(0)
	body := must(id)
	if !body.listed {
		panic("fish: listed")
	}
	if body.seller != caller {
		panic("fish: owner")
	}
	body.price = priceUgnot
	chain.Emit("List", "id", strconv.Itoa(id), "seller", caller.String(), "price", strconv.FormatInt(priceUgnot, 10))
}

func Cancel(cur realm, id int) {
	caller := requireUser(cur)
	takeExact(0)
	body := must(id)
	if !body.listed {
		panic("fish: listed")
	}
	if body.seller != caller {
		panic("fish: owner")
	}
	moveToken(self, self, body.seller, id)
	body.owner = body.seller
	body.seller = address("")
	body.price = 0
	body.listed = false
	chain.Emit("Cancel", "id", strconv.Itoa(id))
}

func Buy(cur realm, id int) {
	caller := requireUser(cur)
	body := must(id)
	if !body.listed {
		panic("fish: listed")
	}
	if caller == body.seller {
		panic("fish: self")
	}
	takeExact(body.price)
	proto := body.price * protocolBps / 10000
	royal := body.price * royaltyBps / 10000
	if proto+royal > body.price {
		panic("fish: fee")
	}
	sellerAmt := body.price - proto - royal
	send(body.seller, sellerAmt, cur)
	send(creator, royal, cur)
	send(protocolSink, proto, cur)
	moveToken(self, self, caller, id)
	body.owner = caller
	body.seller = address("")
	body.price = 0
	body.listed = false
	chain.Emit("Buy", "id", strconv.Itoa(id), "buyer", caller.String())
}

func ItemLine(id int) string {
	body := must(id)
	return strconv.Itoa(body.id) + "|" + body.name + "|" + addrStr(body.owner) + "|" + addrStr(body.seller) + "|" +
		strconv.FormatInt(body.price, 10) + "|" + strconv.FormatBool(body.listed) + "|" + body.image + "|fish|" +
		body.rarity + "|Size:" + body.size + ";Trait:" + body.trait + ";Species:" + body.species + ";HP:" + strconv.Itoa(body.hp) +
		"|true|-1"
}

func ListOpen() string {
	requireInit()
	out := ""
	n := 0
	for _, body := range bodies {
		if body == nil || !body.listed || body.burned {
			continue
		}
		if n >= listCap {
			break
		}
		if out != "" {
			out += "\n"
		}
		out += ItemLine(body.id)
		n++
	}
	return out
}

func addrStr(a address) string {
	if !a.IsValid() {
		return ""
	}
	return a.String()
}
