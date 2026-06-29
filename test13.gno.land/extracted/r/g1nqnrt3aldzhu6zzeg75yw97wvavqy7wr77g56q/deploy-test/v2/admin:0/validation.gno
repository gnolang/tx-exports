package admin

import (
	"net/url"
	"strings"
)

func assertValidAddress(addr address) {
	if !addr.IsValid() {
		panic("invalid address")
	}
}

func assertPositiveFaucetTarget(amount int64) {
	if amount <= 0 {
		panic("faucet target amount must be positive")
	}
}

func assertPositiveUgnotAmount(amount int64) {
	if amount <= 0 {
		panic("amount must be greater than 0")
	}
}

func normalizeExplorerURL(rawURL string) string {
	if rawURL == "" {
		panic("explorer URL is required")
	}
	if strings.TrimSpace(rawURL) != rawURL || strings.ContainsAny(rawURL, " \t\r\n") {
		panic("invalid explorer URL")
	}
	if strings.ContainsAny(rawURL, "[]()") {
		panic("invalid explorer URL")
	}

	parsed, err := url.Parse(rawURL)
	if err != nil || parsed.Host == "" {
		panic("invalid explorer URL")
	}
	if parsed.Scheme != "https" {
		panic("explorer URL must use https")
	}

	normalizedURL := rawURL
	for len(normalizedURL) > len("https://") && strings.HasSuffix(normalizedURL, "/") {
		normalizedURL = normalizedURL[:len(normalizedURL)-1]
	}

	return normalizedURL
}
