package radio

// Main's flow is a pure function of the clock and the stations: between
// listeners' picks, each UTC hour Main simulcasts one genre station, playing
// what it plays (its own picks included) until the next hour. The hour's genre follows an energy line around the
// target of the time of day (UTC dayparts: calm at night, peak in the
// evening): one step below the target in a 3-hour block's first hour, the
// target in its second, one step above in its third, or the nearest genre
// with a live track. Reads compute it and nothing is written, so it never
// runs dry and costs GnoRadio nothing: no Sync, robot or keeper.

// energy orders every genre from calm to intense; Main falls back on it.
var energy = [NumGenres]int{
	3,  // Ambient
	16, // Cinematic & Classical
	15, // Folk & Acoustic
	14, // Jazz & Blues
	8,  // Lo-fi Beats
	10, // R&B & Soul
	19, // Reggae & Dub
	17, // World
	18, // Latin
	20, // Funk & Disco
	13, // Pop
	9,  // Hip-hop & Rap
	11, // Rock & Indie
	2,  // Synthwave
	1,  // Electronica
	5,  // House
	4,  // Techno
	7,  // Dubstep & Trap
	6,  // Drum & Bass
	12, // Metal & Punk
}

// mainFlow is what Main relays by default, from calm to intense: the
// mainstream genres. The niche ones (Ambient, Cinematic, Synthwave, Techno,
// Dubstep, Drum & Bass, Metal, World) keep their own stations; Main reaches
// for them only when none of these has a live track.
var mainFlow = []int{
	8,  // Lo-fi Beats
	14, // Jazz & Blues
	15, // Folk & Acoustic
	10, // R&B & Soul
	19, // Reggae & Dub
	13, // Pop
	18, // Latin
	11, // Rock & Indie
	9,  // Hip-hop & Rap
	20, // Funk & Disco
	1,  // Electronica
	5,  // House
}

// dayparts is the target index in mainFlow for each 3-hour block of the UTC
// day: Jazz, Lo-fi, Folk, R&B, Pop, Rock, Funk & Disco, then House late at night.
var dayparts = [8]int{1, 0, 2, 3, 5, 7, 9, 11}

// hourGenre is the genre Main relays at ts: the daypart's target, one step
// below it in the block's first hour, above it in the last, or the nearest
// mainstream genre with a live track, else any genre with one (0: none).
func hourGenre(t *tx, ts int64) int {
	h := ts / 3600
	if g := nearestLive(t, mainFlow, dayparts[h%24/3]+int(h%3)-1); g > 0 {
		return g
	}
	return nearestLive(t, energy[:], 0)
}

// nearestLive is the genre of order nearest to index i with a live track, the
// calmer one first on a tie (0: none).
func nearestLive(t *tx, order []int, i int) int {
	if i < 0 {
		i = 0
	} else if i >= len(order) {
		i = len(order) - 1
	}
	for k := 0; k < 2*len(order); k++ {
		if j := i + (k+1)/2*(1-2*(k%2)); j >= 0 && j < len(order) && t.hasLive(order[j]) {
			return order[j]
		}
	}
	return 0
}

// HourGenre is the genre Main relays at unix time at (0: none), for pages
// that explain it.
func HourGenre(at int64) int { return hourGenre(rd(), at) }
