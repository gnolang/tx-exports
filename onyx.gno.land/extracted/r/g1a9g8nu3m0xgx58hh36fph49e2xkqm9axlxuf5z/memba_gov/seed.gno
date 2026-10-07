package memba_gov

// Stage 0 roster: T5 throwaway onyx-1 keys.

type seat struct {
	id     string
	addr   address
	weight int
}

var seedSeated = []seat{
	{"z", "g107tjj55ynypmzpdry3lqsaz2ktazh5px7dhyus", 2},
	{"a", "g12k59gme842a6a2u6v633lgzcpnc8tjahdm37hp", 1},
	{"b", "g1wc2ak85823hsjuvqk0lrt7e0z9lylpj043qfne", 1},
	{"c", "g1cff8sps43hqa2z2jwh3plgm03nup49kkvcux82", 1},
}

var seedInvited = []seat{
	{"i", "g1ckh56zjd9plq7rewhan0598c8j6ccqyggjc2q5", 1},
}
