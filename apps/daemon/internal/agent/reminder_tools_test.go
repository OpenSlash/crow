package agent

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

type memReminders struct{ items []Reminder }

func (m *memReminders) CreateReminder(text string, due time.Time) (Reminder, error) {
	r := Reminder{ID: "rem-1", Text: text, DueAt: due}
	m.items = append(m.items, r)
	return r, nil
}
func (m *memReminders) PendingReminders() ([]Reminder, error) { return m.items, nil }
func (m *memReminders) CancelReminder(id string) (bool, error) {
	for i, r := range m.items {
		if r.ID == id {
			m.items = append(m.items[:i], m.items[i+1:]...)
			return true, nil
		}
	}
	return false, nil
}

func TestReminderDue(t *testing.T) {
	loc := time.FixedZone("CST", 8*3600)
	current := time.Date(2026, 11, 20, 14, 30, 0, 0, loc)
	cases := []struct {
		at      string
		minutes float64
		want    string
	}{
		{"", 10, "2026-11-20 14:40"},
		{"15:00", 0, "2026-11-20 15:00"},
		{"09:00", 0, "2026-11-21 09:00"}, // already passed today
		{"2026-11-25 08:30", 0, "2026-11-25 08:30"},
	}
	for _, c := range cases {
		got, err := reminderDue(c.at, c.minutes, current)
		if err != nil || got.In(loc).Format("2006-01-02 15:04") != c.want {
			t.Errorf("reminderDue(%q, %v) = %v, %v; want %s", c.at, c.minutes, got, err, c.want)
		}
	}
	for _, bad := range []string{"", "2026-11-19 10:00", "2028-01-01 00:00", "tomorrow"} {
		if _, err := reminderDue(bad, 0, current); err == nil {
			t.Errorf("reminderDue(%q) should fail", bad)
		}
	}
}

func TestReminderTools(t *testing.T) {
	store := &memReminders{}
	tools := ReminderTools(store)
	run := func(i int, args string) (string, error) {
		res, err := tools[i].Run(context.Background(), json.RawMessage(args))
		return res.Content, err
	}
	if out, err := run(0, `{"text":"喝水","in_minutes":30}`); err != nil || !strings.Contains(out, "rem-1") {
		t.Fatalf("create = %q, %v", out, err)
	}
	if out, _ := run(1, `{}`); !strings.Contains(out, "喝水") {
		t.Fatalf("list = %q", out)
	}
	if _, err := run(2, `{"id":"rem-9"}`); err == nil {
		t.Fatal("cancelling a missing reminder should fail")
	}
	if out, err := run(2, `{"id":"rem-1"}`); err != nil || len(store.items) != 0 {
		t.Fatalf("cancel = %q, %v", out, err)
	}
}

func TestSystemPromptHasTime(t *testing.T) {
	now = func() time.Time { return time.Date(2026, 11, 20, 14, 30, 0, 0, time.FixedZone("CST", 8*3600)) }
	defer func() { now = time.Now }()
	if got := systemPrompt(RespondRequest{}); !strings.Contains(got, "Current local time: Friday 2026-11-20 14:30 CST (UTC+08:00).") {
		t.Fatalf("prompt = %q", got)
	}
}
