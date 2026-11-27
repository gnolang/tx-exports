// Package strategies holds starter bots written as plain functions. Copy one
// as a starting point for your own bot.
package strategies

import "gno.land/p/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/bot"

// Hunter goes for the nearest coin and attacks when the enemy is next to it.
func Hunter(s bot.State) bot.Action {
	if bot.Adjacent(s.Me, s.Enemy) && s.EnemyGold > 0 {
		return bot.Attack
	}
	if c, ok := s.NearestCoin(); ok {
		return bot.StepToward(s.Me, c)
	}
	return bot.StepToward(s.Me, s.Enemy)
}

// Brawler chases the enemy and fights. Once it is ahead it defends.
func Brawler(s bot.State) bot.Action {
	if bot.Adjacent(s.Me, s.Enemy) {
		if s.Winning() {
			return bot.Defend
		}
		return bot.Attack
	}
	if s.EnemyGold == 0 {
		if c, ok := s.NearestCoin(); ok {
			return bot.StepToward(s.Me, c)
		}
	}
	return bot.StepToward(s.Me, s.Enemy)
}

// Trickster collects coins and, when the enemy is next to it, alternates
// between parrying and attacking so a predictable attacker walks into parries.
func Trickster(s bot.State) bot.Action {
	if bot.Adjacent(s.Me, s.Enemy) {
		if s.Turn%2 == 0 && s.MyGold > 0 {
			return bot.Defend
		}
		if s.EnemyGold > 0 {
			return bot.Attack
		}
	}
	if c, ok := s.NearestCoin(); ok {
		return bot.StepToward(s.Me, c)
	}
	return bot.Defend
}

// Coward collects coins but runs from the enemy, and defends when cornered.
func Coward(s bot.State) bot.Action {
	if bot.Dist(s.Me, s.Enemy) <= 2 {
		if a := bot.StepAway(s.Me, s.Enemy); a != bot.Stay {
			return a
		}
		return bot.Defend
	}
	if c, ok := s.NearestCoin(); ok {
		return bot.StepToward(s.Me, c)
	}
	return bot.Stay
}
