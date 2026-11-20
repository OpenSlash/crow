package store

import (
	"database/sql"
	"os"
	"path/filepath"
	"time"

	crowv1 "github.com/crow/crow/apps/daemon/gen/crow/v1"
	_ "github.com/mattn/go-sqlite3"
)

type Store struct {
	db *sql.DB
}

func OpenDefault() (*Store, error) {
	base, err := os.UserConfigDir()
	if err != nil {
		return nil, err
	}
	dir := filepath.Join(base, "Crow")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	return Open(filepath.Join(dir, "crowd.db"))
}

func Open(path string) (*Store, error) {
	db, err := sql.Open("sqlite3", path)
	if err != nil {
		return nil, err
	}
	store := &Store{db: db}
	if err := store.Migrate(); err != nil {
		_ = db.Close()
		return nil, err
	}
	return store, nil
}

func (s *Store) Close() error {
	return s.db.Close()
}

func (s *Store) Migrate() error {
	statements := []string{
		`PRAGMA journal_mode=WAL;`,
		`CREATE TABLE IF NOT EXISTS tasks (
			id TEXT PRIMARY KEY,
			title TEXT NOT NULL,
			kind TEXT NOT NULL,
			status TEXT NOT NULL,
			subtitle TEXT NOT NULL,
			created_at TEXT NOT NULL,
			updated_at TEXT NOT NULL
		);`,
		`CREATE INDEX IF NOT EXISTS idx_tasks_created_at ON tasks(created_at);`,
		`CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);`,
		`CREATE TABLE IF NOT EXISTS task_events (
			id TEXT PRIMARY KEY,
			task_id TEXT NOT NULL,
			type TEXT NOT NULL,
			title TEXT NOT NULL,
			message TEXT NOT NULL,
			created_at TEXT NOT NULL,
			FOREIGN KEY(task_id) REFERENCES tasks(id)
		);`,
		`CREATE INDEX IF NOT EXISTS idx_task_events_task_id_created_at ON task_events(task_id, created_at);`,
		`CREATE TABLE IF NOT EXISTS approval_requests (
			id TEXT PRIMARY KEY,
			task_id TEXT NOT NULL,
			title TEXT NOT NULL,
			description TEXT NOT NULL,
			risk_level INTEGER NOT NULL,
			proposed_action TEXT NOT NULL,
			preview TEXT NOT NULL,
			status TEXT NOT NULL,
			created_at TEXT NOT NULL,
			decided_at TEXT,
			FOREIGN KEY(task_id) REFERENCES tasks(id)
		);`,
		`CREATE INDEX IF NOT EXISTS idx_approval_requests_task_id ON approval_requests(task_id);`,
		`CREATE INDEX IF NOT EXISTS idx_approval_requests_status ON approval_requests(status);`,
		`CREATE TABLE IF NOT EXISTS approval_decisions (
			id TEXT PRIMARY KEY,
			approval_id TEXT NOT NULL,
			task_id TEXT NOT NULL,
			approved INTEGER NOT NULL,
			comment TEXT NOT NULL,
			decided_at TEXT NOT NULL,
			FOREIGN KEY(approval_id) REFERENCES approval_requests(id),
			FOREIGN KEY(task_id) REFERENCES tasks(id)
		);`,
	}
	for _, statement := range statements {
		if _, err := s.db.Exec(statement); err != nil {
			return err
		}
	}
	return nil
}

func (s *Store) CreateTask(task *crowv1.Task, events ...*crowv1.TaskEvent) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	if _, err := tx.Exec(
		`INSERT INTO tasks (id, title, kind, status, subtitle, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)`,
		task.Id,
		task.Title,
		task.Kind,
		task.Status,
		task.Subtitle,
		task.CreatedAt,
		task.UpdatedAt,
	); err != nil {
		return err
	}
	for _, event := range events {
		if err := insertEvent(tx, event); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (s *Store) AddEvent(event *crowv1.TaskEvent, status string, subtitle string, updatedAt string) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	if status != "" || subtitle != "" {
		if _, err := tx.Exec(
			`UPDATE tasks SET status = COALESCE(NULLIF(?, ''), status), subtitle = COALESCE(NULLIF(?, ''), subtitle), updated_at = ? WHERE id = ?`,
			status,
			subtitle,
			updatedAt,
			event.TaskId,
		); err != nil {
			return err
		}
	}
	if err := insertEvent(tx, event); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) UpdateTaskStatus(taskID string, status string, subtitle string, updatedAt string) error {
	_, err := s.db.Exec(
		`UPDATE tasks SET status = ?, subtitle = ?, updated_at = ? WHERE id = ?`,
		status,
		subtitle,
		updatedAt,
		taskID,
	)
	return err
}

func (s *Store) CreateApproval(approval *crowv1.Approval) error {
	_, err := s.db.Exec(
		`INSERT INTO approval_requests (id, task_id, title, description, risk_level, proposed_action, preview, status, created_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		approval.Id,
		approval.TaskId,
		approval.Title,
		approval.Description,
		approval.RiskLevel,
		approval.ProposedAction,
		approval.Preview,
		approval.Status,
		approval.CreatedAt,
	)
	return err
}

func insertEvent(tx *sql.Tx, event *crowv1.TaskEvent) error {
	_, err := tx.Exec(
		`INSERT INTO task_events (id, task_id, type, title, message, created_at) VALUES (?, ?, ?, ?, ?, ?)`,
		event.Id,
		event.TaskId,
		event.Type,
		event.Title,
		event.Message,
		event.CreatedAt,
	)
	return err
}

func (s *Store) ListTasks(limit int, status string) ([]*crowv1.Task, error) {
	if limit <= 0 || limit > 100 {
		limit = 50
	}
	query := `
		SELECT id, title, kind, status, subtitle, created_at, updated_at
		FROM tasks
	`
	args := []any{}
	if status != "" {
		query += ` WHERE status = ?`
		args = append(args, status)
	}
	query += ` ORDER BY created_at DESC LIMIT ?`
	args = append(args, limit)

	rows, err := s.db.Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	tasks := []*crowv1.Task{}
	for rows.Next() {
		task := &crowv1.Task{}
		if err := rows.Scan(&task.Id, &task.Title, &task.Kind, &task.Status, &task.Subtitle, &task.CreatedAt, &task.UpdatedAt); err != nil {
			return nil, err
		}
		tasks = append(tasks, task)
	}
	return tasks, rows.Err()
}

func (s *Store) GetTask(taskID string) (*crowv1.Task, []*crowv1.TaskEvent, *crowv1.Approval, error) {
	task := &crowv1.Task{}
	if err := s.db.QueryRow(`
		SELECT id, title, kind, status, subtitle, created_at, updated_at
		FROM tasks
		WHERE id = ?
	`, taskID).Scan(&task.Id, &task.Title, &task.Kind, &task.Status, &task.Subtitle, &task.CreatedAt, &task.UpdatedAt); err != nil {
		return nil, nil, nil, err
	}

	events, err := s.ListTaskEvents(taskID)
	if err != nil {
		return nil, nil, nil, err
	}
	approval, err := s.GetPendingApproval(taskID)
	if err != nil {
		return nil, nil, nil, err
	}
	return task, events, approval, nil
}

func (s *Store) ListTaskEvents(taskID string) ([]*crowv1.TaskEvent, error) {
	rows, err := s.db.Query(`
		SELECT id, task_id, type, title, message, created_at
		FROM task_events
		WHERE task_id = ?
		ORDER BY created_at ASC
	`, taskID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	events := []*crowv1.TaskEvent{}
	for rows.Next() {
		event := &crowv1.TaskEvent{}
		if err := rows.Scan(&event.Id, &event.TaskId, &event.Type, &event.Title, &event.Message, &event.CreatedAt); err != nil {
			return nil, err
		}
		events = append(events, event)
	}
	return events, rows.Err()
}

func (s *Store) ListPendingApprovals() ([]*crowv1.Approval, error) {
	rows, err := s.db.Query(`
		SELECT id, task_id, title, description, risk_level, proposed_action, preview, status, created_at, COALESCE(decided_at, '')
		FROM approval_requests
		WHERE status = 'pending'
		ORDER BY created_at DESC
	`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	approvals := []*crowv1.Approval{}
	for rows.Next() {
		approval := &crowv1.Approval{}
		if err := rows.Scan(
			&approval.Id,
			&approval.TaskId,
			&approval.Title,
			&approval.Description,
			&approval.RiskLevel,
			&approval.ProposedAction,
			&approval.Preview,
			&approval.Status,
			&approval.CreatedAt,
			&approval.DecidedAt,
		); err != nil {
			return nil, err
		}
		approvals = append(approvals, approval)
	}
	return approvals, rows.Err()
}

func (s *Store) GetPendingApproval(taskID string) (*crowv1.Approval, error) {
	approval := &crowv1.Approval{}
	err := s.db.QueryRow(`
		SELECT id, task_id, title, description, risk_level, proposed_action, preview, status, created_at, COALESCE(decided_at, '')
		FROM approval_requests
		WHERE task_id = ? AND status = 'pending'
		ORDER BY created_at DESC
		LIMIT 1
	`, taskID).Scan(
		&approval.Id,
		&approval.TaskId,
		&approval.Title,
		&approval.Description,
		&approval.RiskLevel,
		&approval.ProposedAction,
		&approval.Preview,
		&approval.Status,
		&approval.CreatedAt,
		&approval.DecidedAt,
	)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return approval, nil
}

func (s *Store) DecideApproval(approvalID string, approved bool, comment string) (*crowv1.Approval, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	approval := &crowv1.Approval{}
	if err := tx.QueryRow(`
		SELECT id, task_id, title, description, risk_level, proposed_action, preview, status, created_at, COALESCE(decided_at, '')
		FROM approval_requests
		WHERE id = ?
	`, approvalID).Scan(
		&approval.Id,
		&approval.TaskId,
		&approval.Title,
		&approval.Description,
		&approval.RiskLevel,
		&approval.ProposedAction,
		&approval.Preview,
		&approval.Status,
		&approval.CreatedAt,
		&approval.DecidedAt,
	); err != nil {
		return nil, err
	}

	status := "rejected"
	taskStatus := "failed"
	taskSubtitle := "Permission rejected"
	approvedValue := 0
	if approved {
		status = "approved"
		taskStatus = "running"
		taskSubtitle = "Continuing"
		approvedValue = 1
	}
	decidedAt := time.Now().Format(time.RFC3339)
	if _, err := tx.Exec(`UPDATE approval_requests SET status = ?, decided_at = ? WHERE id = ?`, status, decidedAt, approvalID); err != nil {
		return nil, err
	}
	if _, err := tx.Exec(`UPDATE tasks SET status = ?, subtitle = ?, updated_at = ? WHERE id = ?`, taskStatus, taskSubtitle, decidedAt, approval.TaskId); err != nil {
		return nil, err
	}
	if _, err := tx.Exec(
		`INSERT INTO approval_decisions (id, approval_id, task_id, approved, comment, decided_at) VALUES (?, ?, ?, ?, ?, ?)`,
		"decision_"+approvalID+"_"+decidedAt,
		approvalID,
		approval.TaskId,
		approvedValue,
		comment,
		decidedAt,
	); err != nil {
		return nil, err
	}
	approval.Status = status
	approval.DecidedAt = decidedAt
	return approval, tx.Commit()
}
