package pearlpass

type Passport struct {
	Owner       address
	Username    string
	Bio         string
	XP          int
	QuestCount  int
	Joined      bool
	QuestWallet bool
	QuestRealm  bool
	QuestName   bool
}

var passports = map[address]Passport{}

func Register(cur realm, username string, bio string) {
	if !cur.IsCurrent() {
		panic("invalid realm")
	}

	if username == "" {
		panic("username cannot be empty")
	}

	if len(username) > 32 {
		panic("username is too long")
	}

	if len(bio) > 160 {
		panic("bio is too long")
	}

	owner := cur.Previous().Address()
	passport := passports[owner]

	if passport.Joined {
		panic("passport already registered")
	}

	passports[owner] = Passport{
		Owner:    owner,
		Username: username,
		Bio:      bio,
		XP:       10,
		Joined:   true,
	}
}

func UpdateBio(cur realm, bio string) {
	if !cur.IsCurrent() {
		panic("invalid realm")
	}

	if len(bio) > 160 {
		panic("bio is too long")
	}

	owner := cur.Previous().Address()
	passport := passports[owner]

	if !passport.Joined {
		panic("passport not registered")
	}

	passport.Bio = bio
	passports[owner] = passport
}

func CompleteQuest(cur realm, quest string) {
	if !cur.IsCurrent() {
		panic("invalid realm")
	}

	owner := cur.Previous().Address()
	passport := passports[owner]

	if !passport.Joined {
		panic("passport not registered")
	}

	if quest == "wallet" {
		if passport.QuestWallet {
			panic("wallet quest already completed")
		}

		passport.QuestWallet = true
		passport.XP += 25
		passport.QuestCount++
	} else if quest == "realm" {
		if passport.QuestRealm {
			panic("realm quest already completed")
		}

		passport.QuestRealm = true
		passport.XP += 50
		passport.QuestCount++
	} else if quest == "name" {
		if passport.QuestName {
			panic("name quest already completed")
		}

		passport.QuestName = true
		passport.XP += 75
		passport.QuestCount++
	} else {
		panic("unknown quest")
	}

	passports[owner] = passport
}

func GetPassport(owner address) Passport {
	return passports[owner]
}

func GetXP(owner address) int {
	return passports[owner].XP
}

func GetBadge(owner address) string {
	xp := passports[owner].XP

	if xp >= 150 {
		return "Pearl Legend"
	}

	if xp >= 75 {
		return "Pearl Builder"
	}

	if xp >= 25 {
		return "Pearl Explorer"
	}

	if xp >= 10 {
		return "Pearl Starter"
	}

	return "No badge"
}

func HasCompletedQuest(owner address, quest string) bool {
	passport := passports[owner]

	if quest == "wallet" {
		return passport.QuestWallet
	}

	if quest == "realm" {
		return passport.QuestRealm
	}

	if quest == "name" {
		return passport.QuestName
	}

	return false
}

func Render(_ string) string {
	return "Pearl Passport aktif.\n" +
		"Register profil, selesaikan quest, dan kumpulkan XP."
}
