package nisse

import "strconv"

type Message struct {
	ID   uint64
	From string
	To   string
	Body string
	Turn uint64
}

var messages map[string]map[uint64]*Message
var nextMessageID uint64

func init() {
	messages = make(map[string]map[uint64]*Message)
	nextMessageID = 1
}

func pairSeed(from string, to string) uint64 {
	source := normalizeKey(from) + "::" + normalizeKey(to)
	sum := uint64(0)
	for i := 0; i < len(source); i++ {
		sum += uint64(source[i]) * uint64(i+1)
	}
	return sum%251 + 1
}

func hexDigit(n uint8) byte {
	if n < 10 {
		return byte('0' + n)
	}
	return byte('a' + (n - 10))
}

func encodeMessage(from string, to string, body string) string {
	seed := pairSeed(from, to)
	out := ""
	for i := 0; i < len(body); i++ {
		mask := uint8((seed + uint64(i*17)) % 256)
		encoded := uint8(body[i]) ^ mask
		out += string([]byte{hexDigit(encoded >> 4), hexDigit(encoded & 15)})
	}
	return out
}

func WriteToFriend(cur realm, fromPlayerName string, toPlayerName string, body string) string {
	caller := callerFromCur(cur)
	fromPlayerName = cleanName(fromPlayerName)
	toPlayerName = cleanName(toPlayerName)
	body = cleanName(body)

	if fromPlayerName == "" || toPlayerName == "" {
		panic("both player names are required")
	}
	if body == "" {
		panic("message body is required")
	}

	fromKey := normalizeKey(fromPlayerName)
	toKey := normalizeKey(toPlayerName)
	fromPlayer, ok := players[fromKey]
	if !ok {
		panic("sender not found")
	}
	if fromPlayer.Owner != caller {
		panic("only the player owner can write messages")
	}
	toPlayer, ok := players[toKey]
	if !ok {
		panic("recipient not found")
	}

	if messages[toKey] == nil {
		messages[toKey] = make(map[uint64]*Message)
	}

	id := nextMessageID
	nextMessageID++
	messages[toKey][id] = &Message{
		ID:   id,
		From: fromPlayer.Name,
		To:   toPlayer.Name,
		Body: encodeMessage(fromPlayer.Name, toPlayer.Name, body),
		Turn: fromPlayer.Turns,
	}

	return "message sent"
}

func GetMessages(playerName string) string {
	key := normalizeKey(playerName)
	entryMap, ok := messages[key]
	if !ok {
		return "No messages."
	}
	if len(entryMap) == 0 {
		return "No messages."
	}

	out := "Messages for " + playerName + "\n"
	for id := uint64(1); id < nextMessageID; id++ {
		entry, exists := entryMap[id]
		if !exists {
			continue
		}
		out += "- #" + strconv.Itoa(int(entry.ID)) + " from " + entry.From + ": " + entry.Body + "\n"
	}
	return out
}

func DescribeLatestIncomingMessage(playerName string) string {
	key := normalizeKey(playerName)
	entryMap, ok := messages[key]
	if !ok {
		return "No messages."
	}
	if len(entryMap) == 0 {
		return "No messages."
	}

	var latest *Message
	for id := uint64(1); id < nextMessageID; id++ {
		entry, exists := entryMap[id]
		if !exists {
			continue
		}
		latest = entry
	}
	if latest == nil {
		return "No messages."
	}

	out := "Latest message for " + playerName + "\n"
	out += "From: " + latest.From + "\n"
	out += "Turn: " + strconv.Itoa(int(latest.Turn)) + "\n"
	out += "Body: " + latest.Body
	return out
}
