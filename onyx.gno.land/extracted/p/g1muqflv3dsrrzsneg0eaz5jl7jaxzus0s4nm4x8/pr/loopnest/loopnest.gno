package loopnest

func F(s []string) { for i := 1; i < len(s); i++ { for j := i; j > 0 && s[j] < s[j-1]; j-- { s[j], s[j-1] = s[j-1], s[j] } } }
