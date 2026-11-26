package realmflow2

import (
    "strconv"
    "strings"
)

type Scenario struct {
    ID int
    Author address
    Title string
    TargetRealm string
    Payload string
    VerifyCount int
}

var scenarios []Scenario

func RegisterScenario(cur realm, title string, targetRealm string, payload string) int {
    id := len(scenarios) + 1
    scenarios = append(scenarios, Scenario{id, cur.Previous().Address(), title, targetRealm, payload, 0})
    return id
}

func VerifyScenario(cur realm, id int) int {
    if id < 1 || id > len(scenarios) { panic("scenario not found") }
    scenarios[id-1].VerifyCount++
    return scenarios[id-1].VerifyCount
}

func GetScenario(id int) string {
    if id < 1 || id > len(scenarios) { return "" }
    s := scenarios[id-1]
    return strconv.Itoa(s.ID) + " | " + s.Author.String() + " | " + s.Title + " | " + s.TargetRealm + " | " + s.Payload + " | " + strconv.Itoa(s.VerifyCount)
}

func GetScenarioCount() int { return len(scenarios) }

func cell(s string) string {
    return strings.ReplaceAll(strings.ReplaceAll(s, "\n", " "), "|", "\\|")
}

func Render(path string) string {
    path = strings.Trim(path, "/")
    if strings.HasPrefix(path, "scenario/") {
        id, err := strconv.Atoi(strings.TrimPrefix(path, "scenario/"))
        if err != nil || id < 1 || id > len(scenarios) { return "# Scenario not found" }
        s := scenarios[id-1]
        return "# " + cell(s.Title) + "\n\n- **ID:** " + strconv.Itoa(s.ID) + "\n- **Target realm:** `" + cell(s.TargetRealm) + "`\n- **Verifications:** " + strconv.Itoa(s.VerifyCount) + "\n- **Author:** `" + s.Author.String() + "`\n\n[Open in RealmFlow](https://realm-flow.vercel.app/?s=" + s.Payload + ")\n\n[Back to catalog](../)"
    }
    if path != "" { return "# Page not found" }
    var b strings.Builder
    b.WriteString("# RealmFlow Registry\n\nShared realm scenarios.\n\n| ID | Title | Target Realm | Verifications | Author | Open in RealmFlow |\n| --- | --- | --- | --- | --- | --- |\n")
    for _, s := range scenarios {
        id := strconv.Itoa(s.ID)
        b.WriteString("| [" + id + "](scenario/" + id + ") | " + cell(s.Title) + " | " + cell(s.TargetRealm) + " | " + strconv.Itoa(s.VerifyCount) + " | " + s.Author.String() + " | [Open](https://realm-flow.vercel.app/?s=" + s.Payload + ") |\n")
    }
    return b.String()
}
