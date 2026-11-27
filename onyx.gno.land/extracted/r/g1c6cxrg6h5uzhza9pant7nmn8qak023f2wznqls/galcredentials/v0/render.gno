package galcredentials

import (
	"strconv"
	"strings"
)

const homeHeader = "# GALcredentials\n\nAgent Passport / spending guard for AI agents on Gno.land.\n\n"

// Render shows the realm in gnoweb. "" or "/" lists all credentials;
// "/<agent>" or ":<agent>" shows one credential. gnoweb links detail
// pages with the ":" form (…/galcredentials/v0:<agent>), so both are
// accepted.
func Render(path string) string {
	agent := strings.Trim(path, "/:")
	if agent == "" {
		if len(credentials) == 0 {
			return homeHeader + "No credentials yet.\n"
		}
		out := homeHeader + "## Credentials\n\n"
		for _, cred := range credentials {
			out += "- " + string(cred.Agent) + ": " + string(cred.Status) +
				", per-tx " + strconv.FormatInt(cred.PerTxLimit, 10) +
				", daily " + strconv.FormatInt(cred.DailyLimit, 10) + "\n"
		}
		return out
	}
	cred, ok := Get(address(agent))
	if !ok {
		return homeHeader + "Credential not found.\n"
	}
	out := homeHeader + "## Credential " + string(cred.Agent) + "\n\n" +
		"- Owner: " + string(cred.Owner) + "\n" +
		"- Status: " + string(cred.Status) + "\n" +
		"- Per-transaction limit: " + strconv.FormatInt(cred.PerTxLimit, 10) + "\n" +
		"- Daily limit: " + strconv.FormatInt(cred.DailyLimit, 10) + "\n" +
		"- Spent today: " + strconv.FormatInt(cred.SpentToday, 10) + "\n" +
		"- Runtime: " + cred.Runtime + "\n"
	if cred.HumanProofHash != "" {
		// The hash is shown in full: it is expected to be a short hex
		// digest. The signature is not printed in full — it can be long
		// (e.g. base64) — only whether one is present is shown.
		out += "- Human proof: " + cred.HumanProofHash + "\n"
		if cred.HumanProofSig != "" {
			out += "- Human proof signature: present\n"
		} else {
			out += "- Human proof signature: absent\n"
		}
	}
	return out
}
