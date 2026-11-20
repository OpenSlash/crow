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

func TestReminders(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "crow.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	now := time.Date(2026, 11, 20, 10, 0, 0, 0, time.UTC)
	a, _ := s.CreateReminder("tea", now.Add(5*time.Minute), now)
	b, _ := s.CreateReminder("meeting", now.Add(time.Hour), now.Add(time.Nanosecond))
	if pending, _ := s.PendingReminders(); len(pending) != 2 || pending[0].Id != a.Id {
		t.Fatalf("pending = %v", pending)
	}
	if fired, _ := s.FireDueReminders(now.Add(time.Minute)); len(fired) != 0 {
		t.Fatalf("fired early = %v", fired)
	}
	fired, _ := s.FireDueReminders(now.Add(6 * time.Minute))
	if len(fired) != 1 || fired[0].Id != a.Id || fired[0].Status != "fired" {
		t.Fatalf("fired = %v", fired)
	}
	if again, _ := s.FireDueReminders(now.Add(7 * time.Minute)); len(again) != 0 {
		t.Fatalf("fired twice = %v", again)
	}
	if unacked, _ := s.UnackedReminders(); len(unacked) != 1 {
		t.Fatalf("unacked = %v", unacked)
	}
	_ = s.AckReminder(a.Id)
	if unacked, _ := s.UnackedReminders(); len(unacked) != 0 {
		t.Fatalf("acked still listed = %v", unacked)
	}
	if ok, _ := s.CancelReminder(b.Id); !ok {
		t.Fatal("cancel failed")
	}
	if ok, _ := s.CancelReminder(a.Id); ok {
		t.Fatal("fired reminder must not be cancellable")
	}
	if pending, _ := s.PendingReminders(); len(pending) != 0 {
		t.Fatalf("pending after cancel = %v", pending)
	}
}
