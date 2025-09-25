package mail

import (
	"fmt"
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


#usage run app using "func main()" below, but endeavor to change "package mail" from above to "package main"

func main() {
	msg := `From: user@example.com
To: another@example.com
Subject: Test email

This is the body of the email.`
	email, err := ReadMessage(msg)
	if err != nil {
		fmt.Println("Error:", err)
		return
	}

	fmt.Println("From:", email.Header["From"])
	fmt.Println("To:", email.Header["To"])
	fmt.Println("Subject:", email.Header["Subject"])
	fmt.Println("Body:", email.Body)
}

func Render(path string) string {
  return "Hello World!"
}
