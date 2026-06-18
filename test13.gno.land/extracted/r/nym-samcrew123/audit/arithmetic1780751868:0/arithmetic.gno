package arithmetic

import counter "gno.land/p/g1hzlg063fqrq4gltql992ssjc0xzau89t5jp63w/audit/pcounter1780751868"

var c = &counter.Counter{Value: 0}

func Inc() {
	counter.Inc(c)
}

func GetValue() int { return c.Value }
