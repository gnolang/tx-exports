// home — Personal Home Realm for Gno.land profile
// This is your on-chain identity. Deploy this to your namespace.
// It serves as your profile page, portfolio, and workspace.
package home

import (
	"strconv"
	"strings"

	"chain/runtime"
)

// Profile represents your Gno.land identity
type Profile struct {
	Name        string
	Bio         string
	GitHub      string
	Discord     string
	Owner       string
	JoinedBlock int64
}

// Project represents a deployed realm/project
type Project struct {
	Name        string
	Description string
	PkgPath     string
	Category    string
}

var (
	profile  *Profile
	projects map[string]*Project
)

func init() {
	profile = &Profile{
		Name:        "Gno Builder",
		Bio:         "Gno.land builder | DeFi & DAO enthusiast",
		GitHub:      "your-github-username",
		Discord:     "your-discord-username",
		JoinedBlock: runtime.ChainHeight(),
	}
	projects = make(map[string]*Project)
}

// === Profile Management ===

// UpdateProfile updates your profile info. First caller becomes owner.
func UpdateProfile(cur realm, name, bio, github, discord string) {
	caller := cur.Previous().Address().String()
	if profile.Owner == "" {
		profile.Owner = caller
	}
	if caller != profile.Owner {
		panic("only owner can update profile")
	}
	profile.Name = name
	profile.Bio = bio
	profile.GitHub = github
	profile.Discord = discord
}

// GetProfile returns profile info
func GetProfile() (string, string, string, string, int64) {
	return profile.Name, profile.Bio, profile.GitHub, profile.Discord, profile.JoinedBlock
}

// GetOwner returns the owner address
func GetOwner() string {
	return profile.Owner
}

// === Project Portfolio ===

// AddProject adds a project to your portfolio
func AddProject(cur realm, name, description, pkgPath, category string) {
	caller := cur.Previous().Address().String()
	if profile.Owner == "" {
		profile.Owner = caller
	}
	if caller != profile.Owner {
		panic("only owner can add projects")
	}
	projects[name] = &Project{
		Name:        name,
		Description: description,
		PkgPath:     pkgPath,
		Category:    category,
	}
}

// GetProject returns project details
func GetProject(name string) (string, string, string) {
	p := projects[name]
	return p.Description, p.PkgPath, p.Category
}

// ProjectCount returns total projects
func ProjectCount() int {
	return len(projects)
}

// ListProjects returns all project names
func ListProjects() []string {
	names := make([]string, 0, len(projects))
	for name := range projects {
		names = append(names, name)
	}
	return names
}

// === Render ===

func Render(_ string) string {
	b := strings.Builder{}
	b.WriteString("# " + profile.Name + "\n\n")
	b.WriteString(profile.Bio + "\n\n")
	b.WriteString("## Links\n")
	b.WriteString("- GitHub: " + profile.GitHub + "\n")
	b.WriteString("- Discord: " + profile.Discord + "\n")
	b.WriteString("- Joined: block " + strconv.FormatInt(profile.JoinedBlock, 10) + "\n\n")

	b.WriteString("## Projects (" + strconv.Itoa(len(projects)) + ")\n")
	for name, p := range projects {
		b.WriteString("### " + name + " [" + p.Category + "]\n")
		b.WriteString(p.Description + "\n")
		b.WriteString("Path: `" + p.PkgPath + "`\n\n")
	}

	b.WriteString("---\n")
	b.WriteString("*Home Realm on Gno.land Pearl testnet*\n")
	return b.String()
}
