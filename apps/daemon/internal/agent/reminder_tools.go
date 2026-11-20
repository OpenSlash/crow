package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/crow/crow/apps/daemon/internal/llm"
)

// Reminder is a one-off reminder the user asked for.
type Reminder struct {
	ID    string
	Text  string
	DueAt time.Time
}

// ReminderStore persists reminders; the daemon fires them when due.
type ReminderStore interface {
	CreateReminder(text string, dueAt time.Time) (Reminder, error)
	PendingReminders() ([]Reminder, error)
	CancelReminder(id string) (bool, error)
}

// maxReminderAhead bounds how far ahead a reminder may be set.
const maxReminderAhead = 366 * 24 * time.Hour

// ReminderTools returns reminder_create, reminder_list and reminder_cancel.
func ReminderTools(store ReminderStore) []Tool {
	return []Tool{reminderCreate{store}, reminderList{store}, reminderCancel{store}}
}

func formatReminderTime(t time.Time) string {
	return t.Local().Format("Mon 2006-01-02 15:04")
}

type reminderCreate struct{ store ReminderStore }

func (reminderCreate) Spec() llm.Tool {
	return llm.Tool{
		Name:        "reminder_create",
		Description: "Set a one-off reminder. Crow speaks it on the island and shows a notification when due. Give either at or in_minutes.",
		Parameters: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"text":       map[string]any{"type": "string", "description": "What to remind the user of, in their language, phrased to be spoken."},
				"at":         map[string]any{"type": "string", "description": `Local time: "YYYY-MM-DD HH:MM", or "HH:MM" for the next such time.`},
				"in_minutes": map[string]any{"type": "number", "description": "Minutes from now."},
			},
			"required": []string{"text"},
		},
	}
}

func (reminderCreate) Activity() Activity {
	return Activity{Kind: ActivityWriting, Label: "Setting a reminder"}
}

func (t reminderCreate) Run(_ context.Context, args json.RawMessage) (ToolResult, error) {
	var in struct {
		Text      string  `json:"text"`
		At        string  `json:"at"`
		InMinutes float64 `json:"in_minutes"`
	}
	if err := json.Unmarshal(args, &in); err != nil {
		return ToolResult{}, fmt.Errorf("invalid arguments: %w", err)
	}
	if strings.TrimSpace(in.Text) == "" {
		return ToolResult{}, errors.New("text is required")
	}
	due, err := reminderDue(in.At, in.InMinutes, now())
	if err != nil {
		return ToolResult{}, err
	}
	r, err := t.store.CreateReminder(strings.TrimSpace(in.Text), due)
	if err != nil {
		return ToolResult{}, err
	}
	return ToolResult{Content: fmt.Sprintf("Reminder %s set for %s.", r.ID, formatReminderTime(r.DueAt))}, nil
}

// reminderDue resolves a reminder time in the local time zone.
func reminderDue(at string, inMinutes float64, current time.Time) (time.Time, error) {
	var due time.Time
	switch at = strings.TrimSpace(at); {
	case inMinutes > 0:
		due = current.Add(time.Duration(inMinutes * float64(time.Minute)))
	case at != "":
		var err error
		due, err = parseReminderTime(at, current)
		if err != nil {
			return time.Time{}, err
		}
	default:
		return time.Time{}, errors.New("give at or in_minutes")
	}
	if !due.After(current) {
		return time.Time{}, fmt.Errorf("%s is in the past", formatReminderTime(due))
	}
	if due.Sub(current) > maxReminderAhead {
		return time.Time{}, errors.New("reminders can be at most a year ahead")
	}
	return due, nil
}

func parseReminderTime(at string, current time.Time) (time.Time, error) {
	loc := current.Location()
	if t, err := time.Parse(time.RFC3339, at); err == nil {
		return t, nil
	}
	for _, layout := range []string{"2006-01-02 15:04", "2006-01-02T15:04", "2006-01-02 15:04:05"} {
		if t, err := time.ParseInLocation(layout, at, loc); err == nil {
			return t, nil
		}
	}
	if t, err := time.ParseInLocation("15:04", at, loc); err == nil {
		due := time.Date(current.Year(), current.Month(), current.Day(), t.Hour(), t.Minute(), 0, 0, loc)
		if !due.After(current) {
			due = due.AddDate(0, 0, 1)
		}
		return due, nil
	}
	return time.Time{}, fmt.Errorf(`cannot read time %q; use "YYYY-MM-DD HH:MM" or "HH:MM"`, at)
}

type reminderList struct{ store ReminderStore }

func (reminderList) Spec() llm.Tool {
	return llm.Tool{
		Name:        "reminder_list",
		Description: "List reminders that have not fired yet.",
		Parameters:  map[string]any{"type": "object", "properties": map[string]any{}},
	}
}

func (reminderList) Activity() Activity {
	return Activity{Kind: ActivityReading, Label: "Checking reminders"}
}

func (t reminderList) Run(context.Context, json.RawMessage) (ToolResult, error) {
	reminders, err := t.store.PendingReminders()
	if err != nil {
		return ToolResult{}, err
	}
	if len(reminders) == 0 {
		return ToolResult{Content: "No pending reminders."}, nil
	}
	lines := make([]string, len(reminders))
	for i, r := range reminders {
		lines[i] = fmt.Sprintf("%s  %s  %s", r.ID, formatReminderTime(r.DueAt), r.Text)
	}
	return ToolResult{Content: strings.Join(lines, "\n")}, nil
}

type reminderCancel struct{ store ReminderStore }

func (reminderCancel) Spec() llm.Tool {
	return llm.Tool{
		Name:        "reminder_cancel",
		Description: "Cancel a pending reminder by id (from reminder_list).",
		Parameters: map[string]any{
			"type":       "object",
			"properties": map[string]any{"id": map[string]any{"type": "string"}},
			"required":   []string{"id"},
		},
	}
}

func (reminderCancel) Activity() Activity {
	return Activity{Kind: ActivityWriting, Label: "Cancelling a reminder"}
}

func (t reminderCancel) Run(_ context.Context, args json.RawMessage) (ToolResult, error) {
	var in struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(args, &in); err != nil {
		return ToolResult{}, fmt.Errorf("invalid arguments: %w", err)
	}
	ok, err := t.store.CancelReminder(strings.TrimSpace(in.ID))
	if err != nil {
		return ToolResult{}, err
	}
	if !ok {
		return ToolResult{}, fmt.Errorf("no pending reminder %q", in.ID)
	}
	return ToolResult{Content: "Cancelled " + in.ID + "."}, nil
}
