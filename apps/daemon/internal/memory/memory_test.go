package memory

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func newStore(t *testing.T) *Store {
	s := Open(t.TempDir())
	s.now = func() time.Time { return time.Date(2026, 11, 20, 9, 30, 0, 0, time.Local) }
	return s
}

func TestResolve(t *testing.T) {
	s := newStore(t)
	for in, want := range map[string]string{
		"profile":             "PROFILE.md",
		"PROFILE.md":          "PROFILE.md",
		"journal":             "journal/2026-11-20.md",
		"topics/咖啡":           "topics/咖啡.md",
		"./topics/go tips.md": "topics/go tips.md",
		"journal/2026-01-02":  "journal/2026-01-02.md",
	} {
		if got, err := s.Resolve(in); err != nil || got != want {
			t.Errorf("Resolve(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	for _, bad := range []string{"../x.md", "topics/../../x.md", "/etc/passwd", "notes.md", "topics/a/b.md", ".git/config", "journal/x.md"} {
		if got, err := s.Resolve(bad); err == nil {
			t.Errorf("Resolve(%q) = %q, want error", bad, got)
		}
	}
}

func TestWriteReadSearch(t *testing.T) {
	s := newStore(t)
	if _, err := s.Write("profile", "Name: Alex\nPrefers short answers", false); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Write("profile", "Drinks oat latte", false); err != nil {
		t.Fatal(err)
	}
	if rel, err := s.Write("journal", "Fixed the build", false); err != nil || rel != "journal/2026-11-20.md" {
		t.Fatalf("journal = %q, %v", rel, err)
	}

	if got := s.Profile(); got != "Name: Alex\nPrefers short answers\nDrinks oat latte" {
		t.Fatalf("profile = %q", got)
	}
	if got, _ := s.Read("journal"); got != "- 09:30 Fixed the build\n" {
		t.Fatalf("journal = %q", got)
	}
	if got, _ := s.Read(""); got != "PROFILE.md\njournal/2026-11-20.md" {
		t.Fatalf("list = %q", got)
	}
	if got, _ := s.Search("oat LATTE"); got != "PROFILE.md:3: Drinks oat latte" {
		t.Fatalf("search = %q", got)
	}

	if _, err := s.Write("profile", "Name: Alex", true); err != nil {
		t.Fatal(err)
	}
	if got := s.Profile(); got != "Name: Alex" {
		t.Fatalf("replaced profile = %q", got)
	}
}

func TestEmptyStore(t *testing.T) {
	s := Open(filepath.Join(t.TempDir(), "missing"))
	if s.Profile() != "" {
		t.Fatal("profile should be empty")
	}
	if got, err := s.Read(""); err != nil || got != "(memory is empty)" {
		t.Fatalf("list = %q, %v", got, err)
	}
	if _, err := s.Read("topics/none"); err == nil {
		t.Fatal("missing file should error")
	}
}

func TestProfileTruncated(t *testing.T) {
	s := newStore(t)
	if _, err := s.Write("profile", strings.Repeat("长", maxProfileBytes), true); err != nil {
		t.Fatal(err)
	}
	if got := s.Profile(); len(got) > maxProfileBytes+4 || !strings.HasSuffix(got, "…") {
		t.Fatalf("profile len = %d", len(got))
	}
}

func TestWriteCommits(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not installed")
	}
	s := newStore(t)
	if _, err := s.Write("topics/coffee", "Oat latte", false); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Write("topics/coffee", "No sugar", false); err != nil {
		t.Fatal(err)
	}
	out, err := s.git("log", "--format=%an %s")
	if err != nil {
		t.Fatal(err, out)
	}
	if out != "Crow Update topics/coffee.md\nCrow Update topics/coffee.md" {
		t.Fatalf("log = %q", out)
	}
	if info, err := os.Stat(filepath.Join(s.dir, "topics", "coffee.md")); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("perm = %v, %v", info, err)
	}
}
