// Package memory keeps Crow's long-term memory as plain Markdown files:
//
//	PROFILE.md            who the user is and how they like things done
//	topics/<topic>.md     notes on a subject
//	journal/YYYY-MM-DD.md what happened on a day
//
// Every change is committed to a local Git repository when git is available,
// so the user can inspect and roll back what Crow remembers.
package memory

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	ProfileFile = "PROFILE.md"
	// maxProfileBytes caps how much of PROFILE.md goes into every system prompt.
	maxProfileBytes = 4000
	maxFileBytes    = 256 << 10
	maxSearchHits   = 20
)

var (
	topicPath   = regexp.MustCompile(`^topics/[\p{L}\p{N}][\p{L}\p{N} _.-]{0,79}\.md$`)
	journalPath = regexp.MustCompile(`^journal/\d{4}-\d{2}-\d{2}\.md$`)
)

type Store struct {
	dir string
	now func() time.Time
	mu  sync.Mutex
}

// DefaultDir is ~/Library/Application Support/Crow/memory.
func DefaultDir() string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return ""
	}
	return filepath.Join(home, "Library", "Application Support", "Crow", "memory")
}

func Open(dir string) *Store {
	return &Store{dir: dir, now: time.Now}
}

func (s *Store) Dir() string { return s.dir }

// Profile returns PROFILE.md, truncated for the system prompt. Missing is "".
func (s *Store) Profile() string {
	data, err := os.ReadFile(filepath.Join(s.dir, ProfileFile))
	if err != nil {
		return ""
	}
	text := strings.TrimSpace(string(data))
	if len(text) > maxProfileBytes {
		text = strings.ToValidUTF8(text[:maxProfileBytes], "") + "\n…"
	}
	return text
}

// Resolve validates a memory path and returns it in canonical form.
// "journal" alone means today's journal.
func (s *Store) Resolve(path string) (string, error) {
	path = strings.TrimSpace(filepath.ToSlash(path))
	path = strings.TrimPrefix(path, "./")
	switch {
	case strings.EqualFold(path, "profile"), strings.EqualFold(path, ProfileFile):
		return ProfileFile, nil
	case path == "journal" || path == "journal/today":
		return "journal/" + s.now().Format("2006-01-02") + ".md", nil
	}
	if !strings.HasSuffix(path, ".md") {
		path += ".md"
	}
	if topicPath.MatchString(path) || journalPath.MatchString(path) {
		if !strings.Contains(path, "..") {
			return path, nil
		}
	}
	return "", fmt.Errorf("invalid memory path %q: use PROFILE.md, topics/<topic>.md or journal/YYYY-MM-DD.md", path)
}

// Read returns a memory file. An empty path lists all files.
func (s *Store) Read(path string) (string, error) {
	if strings.TrimSpace(path) == "" {
		files, err := s.List()
		if err != nil {
			return "", err
		}
		if len(files) == 0 {
			return "(memory is empty)", nil
		}
		return strings.Join(files, "\n"), nil
	}
	rel, err := s.Resolve(path)
	if err != nil {
		return "", err
	}
	data, err := os.ReadFile(filepath.Join(s.dir, rel))
	if errors.Is(err, fs.ErrNotExist) {
		return "", fmt.Errorf("%s does not exist", rel)
	}
	return string(data), err
}

// List returns all memory files, relative to the memory folder.
func (s *Store) List() ([]string, error) {
	var files []string
	err := filepath.WalkDir(s.dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			if errors.Is(err, fs.ErrNotExist) {
				return filepath.SkipAll
			}
			return err
		}
		if d.IsDir() && d.Name() == ".git" {
			return filepath.SkipDir
		}
		if !d.IsDir() && strings.HasSuffix(d.Name(), ".md") {
			rel, _ := filepath.Rel(s.dir, path)
			files = append(files, filepath.ToSlash(rel))
		}
		return nil
	})
	sort.Strings(files)
	return files, err
}

// Write appends to or replaces a memory file and commits the change.
// It returns the canonical path written.
func (s *Store) Write(path, content string, replace bool) (string, error) {
	rel, err := s.Resolve(path)
	if err != nil {
		return "", err
	}
	content = strings.TrimSpace(content)
	if content == "" && !replace {
		return "", errors.New("content is required")
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	full := filepath.Join(s.dir, rel)
	if err := os.MkdirAll(filepath.Dir(full), 0o700); err != nil {
		return "", err
	}
	if !replace {
		existing, _ := os.ReadFile(full)
		if strings.HasPrefix(rel, "journal/") {
			content = "- " + s.now().Format("15:04") + " " + content
		}
		if len(existing) > 0 {
			content = strings.TrimRight(string(existing), "\n") + "\n" + content
		}
	}
	if len(content) > maxFileBytes {
		return "", fmt.Errorf("%s would exceed %d KB; summarize it with replace", rel, maxFileBytes>>10)
	}
	if err := os.WriteFile(full, []byte(content+"\n"), 0o600); err != nil {
		return "", err
	}
	s.commit("Update " + rel)
	return rel, nil
}

// Search returns matching lines as "path:line: text", ranked by how many
// query terms each line contains.
func (s *Store) Search(query string) (string, error) {
	terms := strings.Fields(strings.ToLower(query))
	if len(terms) == 0 {
		return "", errors.New("query is required")
	}
	files, err := s.List()
	if err != nil {
		return "", err
	}
	type hit struct {
		text  string
		score int
	}
	var hits []hit
	for _, rel := range files {
		f, err := os.Open(filepath.Join(s.dir, rel))
		if err != nil {
			continue
		}
		scanner := bufio.NewScanner(f)
		scanner.Buffer(make([]byte, 64<<10), maxFileBytes)
		for n := 1; scanner.Scan(); n++ {
			line := strings.TrimSpace(scanner.Text())
			lower := strings.ToLower(line)
			score := 0
			for _, term := range terms {
				if strings.Contains(lower, term) || strings.Contains(strings.ToLower(rel), term) {
					score++
				}
			}
			if score > 0 && line != "" {
				hits = append(hits, hit{fmt.Sprintf("%s:%d: %s", rel, n, line), score})
			}
		}
		f.Close()
	}
	sort.SliceStable(hits, func(i, j int) bool { return hits[i].score > hits[j].score })
	if len(hits) == 0 {
		return "No matches.", nil
	}
	if len(hits) > maxSearchHits {
		hits = hits[:maxSearchHits]
	}
	lines := make([]string, len(hits))
	for i, h := range hits {
		lines[i] = h.text
	}
	return strings.Join(lines, "\n"), nil
}

// commit records the change in Git. Failures are logged, never fatal.
func (s *Store) commit(message string) {
	if _, err := exec.LookPath("git"); err != nil {
		return
	}
	if _, err := os.Stat(filepath.Join(s.dir, ".git")); err != nil {
		if out, err := s.git("init", "-q"); err != nil {
			log.Printf("memory git init failed: %v %s", err, out)
			return
		}
	}
	if out, err := s.git("add", "-A"); err != nil {
		log.Printf("memory git add failed: %v %s", err, out)
		return
	}
	if out, err := s.git("commit", "-q", "--no-verify", "-m", message); err != nil && !strings.Contains(out, "nothing to commit") {
		log.Printf("memory git commit failed: %v %s", err, out)
	}
}

func (s *Store) git(args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "git", append([]string{"-C", s.dir}, args...)...)
	// A fixed identity and no user/system config keep commits independent of the user's Git setup.
	cmd.Env = append(os.Environ(),
		"GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1",
		"GIT_AUTHOR_NAME=Crow", "GIT_AUTHOR_EMAIL=crow@localhost",
		"GIT_COMMITTER_NAME=Crow", "GIT_COMMITTER_EMAIL=crow@localhost",
	)
	out, err := cmd.CombinedOutput()
	return strings.TrimSpace(string(out)), err
}
