// Package approval decides whether an action needs the user's approval, based
// on one approval level, optional per-scope overrides, and the grants the user
// has already given. Scopes name kinds of action, not tools, so a new executor
// adds no setting of its own.
package approval

import (
	"strings"
	"sync"
	"time"
)

type Scope string

const (
	ScopeComputer Scope = "computer"
	ScopeTerminal Scope = "terminal"
	// ScopeExecutor covers handing work to an executor (Codex, Claude Code, ...)
	// and executor actions that are neither commands nor file changes.
	ScopeExecutor  Scope = "executor"
	ScopeFileWrite Scope = "file_write"
)

var Scopes = []Scope{ScopeComputer, ScopeTerminal, ScopeExecutor, ScopeFileWrite}

// NormalizeScope maps a requested scope to a known one; "codex" is the old
// name of the executor scope.
func NormalizeScope(value string) Scope {
	switch scope := Scope(strings.TrimSpace(strings.ToLower(value))); scope {
	case ScopeComputer, ScopeTerminal, ScopeFileWrite:
		return scope
	default:
		return ScopeExecutor
	}
}

// Level is the single approval setting most users change.
type Level string

const (
	// Cautious asks before every action.
	Cautious Level = "cautious"
	// Balanced asks once per task; terminal commands are asked every time.
	Balanced Level = "balanced"
	// Relaxed asks once, then allows the scope for the grant TTL.
	Relaxed Level = "relaxed"
)

func ParseLevel(value string) Level {
	switch level := Level(strings.TrimSpace(strings.ToLower(value))); level {
	case Cautious, Relaxed:
		return level
	default:
		return Balanced
	}
}

// Policy is the policy a level applies to a scope.
func (l Level) Policy(scope Scope) Policy {
	switch l {
	case Cautious:
		return EveryTurn
	case Relaxed:
		return Once
	default:
		return DefaultPolicy(scope)
	}
}

// Auto is the override value that means "follow the level".
const Auto = "auto"

// ResolvePolicy applies a per-scope override when one is set, else the level.
func ResolvePolicy(level Level, scope Scope, override string) Policy {
	switch value := strings.TrimSpace(strings.ToLower(override)); Policy(value) {
	case EveryTurn, BeforeActing, Once, Never:
		return ParsePolicy(scope, value)
	default:
		return level.Policy(scope)
	}
}

type Policy string

const (
	// EveryTurn asks before every action.
	EveryTurn Policy = "every_turn"
	// BeforeActing asks once per task, before its first action in the scope.
	BeforeActing Policy = "before_acting"
	// Once asks once, then a grant covers the scope for the grant TTL.
	Once Policy = "once"
	// Never does not ask.
	Never Policy = "never"
)

// DefaultGrantTTL is how long a "once" approval lasts.
const DefaultGrantTTL = 30 * time.Minute

// DefaultPolicy is used when the user has not chosen one.
func DefaultPolicy(scope Scope) Policy {
	if scope == ScopeTerminal {
		return EveryTurn
	}
	return BeforeActing
}

// ParsePolicy reads a policy setting. Terminal commands always need some
// approval, so "never" is raised to "once" for the terminal scope.
func ParsePolicy(scope Scope, value string) Policy {
	policy := Policy(strings.TrimSpace(strings.ToLower(value)))
	switch policy {
	case EveryTurn, BeforeActing, Once:
	case Never:
		if scope == ScopeTerminal {
			return Once
		}
	default:
		return DefaultPolicy(scope)
	}
	return policy
}

// GrantStore persists time-limited grants.
type GrantStore interface {
	HasActiveGrant(scope string, now time.Time) (bool, error)
	AddGrant(scope string, createdAt, expiresAt time.Time) error
}

type Gate struct {
	grants GrantStore
	policy func(Scope) Policy
	ttl    func() time.Duration
	now    func() time.Time

	mu      sync.Mutex
	perTask map[string]map[Scope]bool
}

func NewGate(grants GrantStore, policy func(Scope) Policy, ttl func() time.Duration) *Gate {
	return &Gate{grants: grants, policy: policy, ttl: ttl, now: time.Now, perTask: map[string]map[Scope]bool{}}
}

// Allowed reports whether the action may run without asking, and the policy applied.
func (g *Gate) Allowed(taskID string, scope Scope) (bool, Policy) {
	policy := g.policy(scope)
	switch policy {
	case Never:
		return true, policy
	case BeforeActing:
		g.mu.Lock()
		defer g.mu.Unlock()
		return g.perTask[taskID][scope], policy
	case Once:
		ok, err := g.grants.HasActiveGrant(string(scope), g.now())
		return err == nil && ok, policy
	default:
		return false, policy
	}
}

// Record remembers an approval so the policy can skip later prompts.
func (g *Gate) Record(taskID string, scope Scope, approved bool) error {
	if !approved {
		return nil
	}
	switch g.policy(scope) {
	case BeforeActing:
		g.mu.Lock()
		defer g.mu.Unlock()
		if g.perTask[taskID] == nil {
			g.perTask[taskID] = map[Scope]bool{}
		}
		g.perTask[taskID][scope] = true
	case Once:
		now := g.now()
		ttl := g.ttl()
		if ttl <= 0 {
			ttl = DefaultGrantTTL
		}
		return g.grants.AddGrant(string(scope), now, now.Add(ttl))
	}
	return nil
}

// ForgetTask drops per-task approvals once a task ends.
func (g *Gate) ForgetTask(taskID string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	delete(g.perTask, taskID)
}
