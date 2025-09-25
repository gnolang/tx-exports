package mail

import (
	"strings"
)

type Mail struct {
	Header map[string]string
	Body   string
}

func ReadMessage(msg string) (*Mail, error) {
	lines := strings.Split(msg, "\n")
	mail := &Mail{Header: make(map[string]string)}

	isBody := false
	for _, line := range lines {
		if line == "" {
			isBody = true
			continue
		}
		if isBody {
			mail.Body += line + "\n"
		} else {
			parts := strings.SplitN(line, ": ", 2)
			if len(parts) == 2 {
				mail.Header[parts[0]] = parts[1]
			}
		}
	}
	return mail, nil
}
