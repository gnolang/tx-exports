package home

import (
	"std"

	fmt "gno.land/p/demo/ufmt"
)

var (
	wallet   std.Address
	mnemonic string

	PFP   string
	Links []Link

	// map[title]BookInfo
	Bookshelf = make(map[string]BookInfo)

	BookStatusIsToRead  BookStatus = 1
	BookStatusIsReading BookStatus = 2
	BookStatusIsRead    BookStatus = 3
)

func init() {
	wallet = "g1sw5xklxjjuv0yvuxy5f5s3l3mnj0nqq626a9wr"
	// mnemonic = "never gonna give you up never gonna let you down never gonna run around and desert you never gonna make you cry never gonna say goodbye never gonna tell a lie and hurt you"

	PFP = "https://avatars.githubusercontent.com/u/8089712?v=4"

	// Badge are from
	// https://github.com/Ileriayo/markdown-badges
	Links = append(Links,
		Link{
			Name: "github_albttx",
			Logo: "https://img.shields.io/badge/github-%23121011.svg?style=for-the-badge&logo=github&logoColor=white",
			URL:  "https://github.com/albttx",
		},
		Link{
			Name: "x_albttx",
			Logo: "https://img.shields.io/badge/albttx-%23000000.svg?style=for-the-badge&logo=X&logoColor=white",
			URL:  "https://x.com/albttx",
		},
		Link{
			Name: "x_nysa",
			Logo: "https://img.shields.io/badge/nysa--network-%23000000.svg?style=for-the-badge&logo=X&logoColor=white",
			URL:  "https://x.com/nysa_network",
		},
		Link{
			Name: "stackoverflow",
			Logo: "https://img.shields.io/badge/StackExchange-%23ffffff.svg?style=for-the-badge&logo=StackExchange",
			URL:  "https://stackoverflow.com/users/4511585/albttx",
		},
		Link{
			Name: "linkedin",
			Logo: "https://img.shields.io/badge/linkedin-%230077B5.svg?style=for-the-badge&logo=linkedin&logoColor=white",
			URL:  "https://linkedin.com/in/albertlebatteux",
		},
		Link{
			Name: "albttx.eth",
			Logo: "https://img.shields.io/badge/Ethereum-3C3C3D?style=for-the-badge&logo=Ethereum&logoColor=white",
			URL:  "albttx.eth",
		},
		Link{
			Name: "medium",
			Logo: "https://img.shields.io/badge/Medium-12100E?style=for-the-badge&logo=medium&logoColor=white",
			URL:  "https://medium.com/@albttx",
		},
		Link{
			Name: "KeybasePGP",
			Logo: "https://img.shields.io/keybase/pgp/alebatt",
			URL:  "https://keybase.io/alebatt",
		},
	)
}

type Link struct {
	Name string
	Logo string
	URL  string
}

type BookStatus int

type BookInfo struct {
	URL    string
	Status BookStatus
}

func Render(path string) string {
	content := `
# Albert's profile

<div class='columns-2'>
<div class='col-1'>

<img alt="albttx.gno" src="` + PFP + `">

</div>

<div class='col-2'>

## About me

Hi, I'm Albert, but you can find me on almost every platform as 'albttx'.

[42 Alumni](https://42.fr)

I'm french, living in Portugal working remotely a Lead Infrastructure at All in Bits, and a Gnome enthusiast helping whenever i can on [gno.land](https://gno.land)

On my free time, i love spending time with my family and friends, i enjoy climbing, playing chess and boxing.

</div>
</div>
`

	// My Links
	content += "\n## My links\n\n"

	content += "<p align='center'>\n"
	for _, link := range Links {
		if link.Logo == "" && link.URL == "" {
			continue
		}
		content += fmt.Sprintf("<a href='%s'><img src='%s' /></a> &nbsp;\n", link.URL, link.Logo)
	}
	content += "</p>\n\n"

	// Bookshelf
	content += "## Bookshelf\n"
	content += "<div class='columns-3' style='margin: 0;'>\n"

	contentToRead := "<div>\n\n#### TO READ\n\n"
	contentReading := "<div>\n\n#### READING\n\n"
	contentRead := "<div>\n\n#### READ\n\n"

	for title, book := range Bookshelf {
		if book.Status == 0 {
			continue
		}

		switch book.Status {
		case BookStatusIsToRead:
			contentToRead += fmt.Sprintf("- [%s](%s)\n", title, book.URL)
		case BookStatusIsReading:
			contentReading += fmt.Sprintf("- [%s](%s)\n", title, book.URL)
		case BookStatusIsRead:
			contentRead += fmt.Sprintf("- [%s](%s)\n", title, book.URL)
		}
	}

	content += contentToRead + "</div>\n"
	content += contentReading + "</div>\n"
	content += contentRead + "</div>\n"

	content += "</div>"
	return content
}

// SetBook can add,update,delete a book
func SetBook(title, url string, status int) {
	if caller := std.PrevRealm().Addr(); caller != wallet {
		panic("unauthorized")
	}

	Bookshelf[title] = BookInfo{
		URL:    url,
		Status: BookStatus(status),
	}
}

// AddOrUpdateLink
func AddOrUpdateLink(name, logo, url string) {
	if caller := std.PrevRealm().Addr(); caller != wallet {
		panic("unauthorized")
	}

	for i, link := range Links {
		if name == link.Name {
			Links[i].Logo = logo
			Links[i].URL = url
			return
		}
	}

	Links = append(Links, Link{
		Name: name,
		Logo: logo,
		URL:  url,
	})
}

// UpdatePFP
func UpdatePFP(pfp string) {
	if caller := std.PrevRealm().Addr(); caller != wallet {
		panic("unauthorized")
	}

	PFP = pfp
}
