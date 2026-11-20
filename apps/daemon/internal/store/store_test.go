package store

import (
	"path/filepath"
	"testing"
	"time"
)

func TestStorePackageCompiles(t *testing.T) {}

func TestGrants(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "crow.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	now := time.Date(2026, 11, 20, 10, 0, 0, 0, time.UTC)
	if err := s.AddGrant("codex", now, now.Add(30*time.Minute)); err != nil {
		t.Fatal(err)
	}
	if err := s.AddGrant("terminal", now.Add(-time.Hour), now.Add(-time.Minute)); err != nil {
		t.Fatal(err)
	}
	if ok, _ := s.HasActiveGrant("codex", now); !ok {
		t.Fatal("codex grant should be active")
	}
	if ok, _ := s.HasActiveGrant("terminal", now); ok {
		t.Fatal("expired grant should not count")
	}
	grants, err := s.ActiveGrants(now)
	if err != nil || len(grants) != 1 || grants[0].Scope != "codex" {
		t.Fatalf("grants = %v, %v", grants, err)
	}
	if err := s.RevokeGrants(""); err != nil {
		t.Fatal(err)
	}
	if ok, _ := s.HasActiveGrant("codex", now); ok {
		t.Fatal("revoked grant should not count")
	}
}
