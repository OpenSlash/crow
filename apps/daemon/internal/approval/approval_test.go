package approval

import (
	"testing"
	"time"
)

type memGrants struct{ expires map[string]time.Time }

func (m *memGrants) HasActiveGrant(scope string, now time.Time) (bool, error) {
	return now.Before(m.expires[scope]), nil
}

func (m *memGrants) AddGrant(scope string, _, expiresAt time.Time) error {
	m.expires[scope] = expiresAt
	return nil
}

func TestParsePolicy(t *testing.T) {
	cases := []struct {
		scope Scope
		in    string
		want  Policy
	}{
		{ScopeExecutor, "", BeforeActing},
		{ScopeTerminal, "", EveryTurn},
		{ScopeExecutor, " NEVER ", Never},
		{ScopeTerminal, "never", Once},
		{ScopeFileWrite, "bogus", BeforeActing},
		{ScopeComputer, "once", Once},
	}
	for _, c := range cases {
		if got := ParsePolicy(c.scope, c.in); got != c.want {
			t.Errorf("ParsePolicy(%s, %q) = %s, want %s", c.scope, c.in, got, c.want)
		}
	}
}

func TestGate(t *testing.T) {
	policies := map[Scope]Policy{ScopeExecutor: BeforeActing, ScopeTerminal: EveryTurn, ScopeFileWrite: Once, ScopeComputer: Never}
	grants := &memGrants{expires: map[string]time.Time{}}
	now := time.Date(2026, 11, 20, 10, 0, 0, 0, time.UTC)
	g := NewGate(grants, func(s Scope) Policy { return policies[s] }, func() time.Duration { return 30 * time.Minute })
	g.now = func() time.Time { return now }

	allowed := func(task string, s Scope) bool { ok, _ := g.Allowed(task, s); return ok }

	if !allowed("t1", ScopeComputer) {
		t.Error("never should not ask")
	}

	// before_acting: once per task.
	if allowed("t1", ScopeExecutor) {
		t.Error("first executor action should ask")
	}
	_ = g.Record("t1", ScopeExecutor, false)
	if allowed("t1", ScopeExecutor) {
		t.Error("a rejection must not grant")
	}
	_ = g.Record("t1", ScopeExecutor, true)
	if !allowed("t1", ScopeExecutor) || allowed("t2", ScopeExecutor) {
		t.Error("approval should cover only its task")
	}
	g.ForgetTask("t1")
	if allowed("t1", ScopeExecutor) {
		t.Error("forgotten task should ask again")
	}

	// every_turn: always asks.
	_ = g.Record("t1", ScopeTerminal, true)
	if allowed("t1", ScopeTerminal) {
		t.Error("every_turn should always ask")
	}

	// once: grant across tasks until it expires.
	_ = g.Record("t1", ScopeFileWrite, true)
	if !allowed("t9", ScopeFileWrite) {
		t.Error("grant should cover other tasks")
	}
	now = now.Add(31 * time.Minute)
	if allowed("t9", ScopeFileWrite) {
		t.Error("grant should expire")
	}
}

func TestLevelsAndOverrides(t *testing.T) {
	cases := []struct {
		level    string
		scope    Scope
		override string
		want     Policy
	}{
		{"", ScopeExecutor, "", BeforeActing},
		{"", ScopeTerminal, "", EveryTurn},
		{"cautious", ScopeFileWrite, "", EveryTurn},
		{"relaxed", ScopeTerminal, "", Once},
		{"relaxed", ScopeComputer, Auto, Once},
		{"relaxed", ScopeComputer, "every_turn", EveryTurn},
		{"balanced", ScopeTerminal, "never", Once},
		{"bogus", ScopeExecutor, "bogus", BeforeActing},
	}
	for _, c := range cases {
		if got := ResolvePolicy(ParseLevel(c.level), c.scope, c.override); got != c.want {
			t.Errorf("%q %s %q = %s, want %s", c.level, c.scope, c.override, got, c.want)
		}
	}
	if NormalizeScope("codex") != ScopeExecutor || NormalizeScope("") != ScopeExecutor || NormalizeScope(" Terminal ") != ScopeTerminal {
		t.Error("NormalizeScope")
	}
}
