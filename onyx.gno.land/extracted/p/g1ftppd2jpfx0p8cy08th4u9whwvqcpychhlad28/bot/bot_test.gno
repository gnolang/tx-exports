package bot

import "testing"

func TestApplyStaysOnBoard(t *testing.T) {
	corner := Pos{0, 0}
	if got := Apply(corner, Up); got != corner {
		t.Errorf("Up from corner: got %v", got)
	}
	if got := Apply(corner, Left); got != corner {
		t.Errorf("Left from corner: got %v", got)
	}
	if got := Apply(corner, Right); got != (Pos{1, 0}) {
		t.Errorf("Right: got %v", got)
	}
	edge := Pos{Size - 1, Size - 1}
	if got := Apply(edge, Down); got != edge {
		t.Errorf("Down from bottom edge: got %v", got)
	}
	if got := Apply(Pos{3, 3}, Attack); got != (Pos{3, 3}) {
		t.Errorf("Attack must not move: got %v", got)
	}
}

func TestStepTowardAndAway(t *testing.T) {
	if a := StepToward(Pos{0, 0}, Pos{2, 5}); a != Right {
		t.Errorf("want right, got %v", a)
	}
	if a := StepToward(Pos{2, 0}, Pos{2, 5}); a != Down {
		t.Errorf("want down, got %v", a)
	}
	if a := StepToward(Pos{2, 5}, Pos{2, 5}); a != Stay {
		t.Errorf("want stay, got %v", a)
	}
	from, danger := Pos{4, 4}, Pos{4, 5}
	if d := Dist(Apply(from, StepAway(from, danger)), danger); d != 2 {
		t.Errorf("StepAway should increase distance to 2, got %d", d)
	}
}

func TestNearestCoin(t *testing.T) {
	s := State{Me: Pos{0, 0}, Coins: []Pos{{5, 5}, {1, 2}, {8, 0}}}
	c, ok := s.NearestCoin()
	if !ok || c != (Pos{1, 2}) {
		t.Errorf("got %v %v", c, ok)
	}
	if _, ok := (State{}).NearestCoin(); ok {
		t.Error("no coins should report false")
	}
}

func TestActionNames(t *testing.T) {
	if Attack.String() != "attack" || Action(42).String() != "invalid" || Action(-1).Valid() {
		t.Error("bad action names")
	}
}
