package store

import (
	"fmt"
	"strings"
)

func New(kind string, cfg Config) (Store, error) {
	switch strings.ToLower(strings.TrimSpace(kind)) {
	case "", "memory":
		return NewMemory(cfg), nil
	case "firestore":
		return nil, fmt.Errorf("firestore store adapter is not implemented yet")
	case "postgres", "pgsql", "neon":
		return NewPostgres(cfg)
	default:
		return nil, fmt.Errorf("unsupported store adapter %q", kind)
	}
}
