package poker

// Address is a string alias for wallet addresses
type Address = string

// Card represents a playing card
type Card struct {
	Suit  int // 0=Spades, 1=Hearts, 2=Diamonds, 3=Clubs
	Value int // 2-14 (14=Ace)
}

// Player represents a player at the table
type Player struct {
	Address    Address
	Hand       [2]Card
	Chips      int64
	CurrentBet int64
	HasFolded  bool
	IsAllIn    bool
	IsActive   bool
	SeatIndex  int
}

// GameState represents the current phase of a hand
type GameState int

const (
	StateWaiting  GameState = 0 // Waiting for players
	StatePreFlop  GameState = 1 // Hole cards dealt, pre-flop betting
	StateFlop     GameState = 2 // Flop dealt (3 community cards)
	StateTurn     GameState = 3 // Turn dealt (4th community card)
	StateRiver    GameState = 4 // River dealt (5th community card)
	StateShowdown GameState = 5 // All betting complete, determine winner
)

func (gs GameState) String() string {
	switch gs {
	case StateWaiting:
		return "Waiting"
	case StatePreFlop:
		return "Pre-Flop"
	case StateFlop:
		return "Flop"
	case StateTurn:
		return "Turn"
	case StateRiver:
		return "River"
	case StateShowdown:
		return "Showdown"
	default:
		return "Unknown"
	}
}

// Table represents a poker table
type Table struct {
	ID            string
	Name          string
	Creator       Address
	Players       []*Player
	MaxPlayers    int   // 4 or 6
	SmallBlind    int64 // in ugnot (e.g., 2500000 = 2.5 GNOT)
	BigBlind      int64 // in ugnot (e.g., 5000000 = 5 GNOT)
	MinBet        int64 // minimum raise amount
	MaxBet        int64 // maximum single bet
	MinBuyIn      int64 // minimum chips to join
	MaxBuyIn      int64 // maximum chips to join
	Pot           int64
	Community     []Card
	State         GameState
	DealerIdx     int    // Dealer button position
	CurrentTurn   int    // Index of player whose turn it is
	DeckSeed      int64  // Seed for deck shuffle
	HandCount     int    // Number of hands played
	RakeCollected int64  // Total rake collected at this table
}

// HandRank represents the rank of a poker hand
type HandRank int

const (
	HighCard      HandRank = 0
	OnePair       HandRank = 1
	TwoPair       HandRank = 2
	ThreeOfAKind  HandRank = 3
	Straight      HandRank = 4
	Flush         HandRank = 5
	FullHouse     HandRank = 6
	FourOfAKind   HandRank = 7
	StraightFlush HandRank = 8
	RoyalFlush    HandRank = 9
)

func (hr HandRank) String() string {
	switch hr {
	case HighCard:
		return "High Card"
	case OnePair:
		return "One Pair"
	case TwoPair:
		return "Two Pair"
	case ThreeOfAKind:
		return "Three of a Kind"
	case Straight:
		return "Straight"
	case Flush:
		return "Flush"
	case FullHouse:
		return "Full House"
	case FourOfAKind:
		return "Four of a Kind"
	case StraightFlush:
		return "Straight Flush"
	case RoyalFlush:
		return "Royal Flush"
	default:
		return "Unknown"
	}
}

// HandResult stores the evaluated hand result for comparison
type HandResult struct {
	Rank      HandRank
	TieBreak  [5]int // Values for breaking ties, highest first
	BestCards [5]Card
}

// SuitName returns the name of a suit
func SuitName(suit int) string {
	switch suit {
	case 0:
		return "♠"
	case 1:
		return "♥"
	case 2:
		return "♦"
	case 3:
		return "♣"
	default:
		return "?"
	}
}

// ValueName returns the display name of a card value
func ValueName(value int) string {
	switch value {
	case 11:
		return "J"
	case 12:
		return "Q"
	case 13:
		return "K"
	case 14:
		return "A"
	default:
		if value >= 2 && value <= 10 {
			return IntToStr(value)
		}
		return "?"
	}
}

// CardString returns a human-readable string for a card
func CardString(c Card) string {
	return ValueName(c.Value) + SuitName(c.Suit)
}

// IntToStr converts an integer to a string
func IntToStr(n int) string {
	if n == 0 {
		return "0"
	}
	s := ""
	neg := false
	if n < 0 {
		neg = true
		n = -n
	}
	for n > 0 {
		digit := n % 10
		s = string(rune('0'+digit)) + s
		n /= 10
	}
	if neg {
		s = "-" + s
	}
	return s
}
