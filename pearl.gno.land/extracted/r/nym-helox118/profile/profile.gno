package profile

import "strconv"

type UserProfile struct {
	Name string
	Bio  string
}

var profiles = map[address]UserProfile{}

func SetProfile(cur realm, name string, bio string) {
	owner := cur.Previous().Address()

	profiles[owner] = UserProfile{
		Name: name,
		Bio:  bio,
	}
}

func GetProfile(owner address) UserProfile {
	return profiles[owner]
}

func Render(_ string) string {
	return "Profile realm aktif.\n" +
		"Gunakan fungsi SetProfile untuk menyimpan profil."
}

func ProfileCount() int {
	return len(profiles)
}

func Version() string {
	return "Pearl profile v1 - " + strconv.Itoa(len(profiles)) + " profile"
}
