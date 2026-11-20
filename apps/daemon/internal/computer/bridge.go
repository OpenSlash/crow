// Package computer runs computer-use tasks. The model plans actions; the Crow
// app performs them on the Mac through a command bridge and returns screenshots.
package computer

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"time"

	crowv1 "github.com/crow/crow/apps/daemon/gen/crow/v1"
)

// ErrNoApp means no Crow app is connected to perform actions.
var ErrNoApp = errors.New("computer use needs the Crow app to be running")

// commandTimeout bounds one action, including the app waiting for the user to stop typing.
const commandTimeout = 30 * time.Second

// Bridge passes commands to the connected app and waits for results.
type Bridge struct {
	mu      sync.Mutex
	watcher chan *crowv1.ComputerCommand
	pending map[string]chan *crowv1.ComputerResult
	seq     int
}

func NewBridge() *Bridge {
	return &Bridge{pending: map[string]chan *crowv1.ComputerResult{}}
}

// Watch registers the app as the command receiver until ctx ends. A newer
// watcher replaces an older one.
func (b *Bridge) Watch(ctx context.Context) <-chan *crowv1.ComputerCommand {
	ch := make(chan *crowv1.ComputerCommand, 4)
	b.mu.Lock()
	b.watcher = ch
	b.mu.Unlock()
	context.AfterFunc(ctx, func() {
		b.mu.Lock()
		if b.watcher == ch {
			b.watcher = nil
		}
		b.mu.Unlock()
	})
	return ch
}

// Do sends an action to the app and waits for its result.
func (b *Bridge) Do(ctx context.Context, action string, args any) (*crowv1.ComputerResult, error) {
	argsJSON, err := json.Marshal(args)
	if err != nil {
		return nil, err
	}
	b.mu.Lock()
	watcher := b.watcher
	if watcher == nil {
		b.mu.Unlock()
		return nil, ErrNoApp
	}
	b.seq++
	id := fmt.Sprintf("cmd-%d-%d", time.Now().UnixNano(), b.seq)
	result := make(chan *crowv1.ComputerResult, 1)
	b.pending[id] = result
	b.mu.Unlock()
	defer func() {
		b.mu.Lock()
		delete(b.pending, id)
		b.mu.Unlock()
	}()

	ctx, cancel := context.WithTimeout(ctx, commandTimeout)
	defer cancel()
	select {
	case watcher <- &crowv1.ComputerCommand{Id: id, Action: action, ArgsJson: string(argsJSON)}:
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	select {
	case res := <-result:
		return res, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

// Submit delivers a result from the app.
func (b *Bridge) Submit(res *crowv1.ComputerResult) error {
	b.mu.Lock()
	ch := b.pending[res.GetId()]
	b.mu.Unlock()
	if ch == nil {
		return fmt.Errorf("unknown or expired command %q", res.GetId())
	}
	ch <- res
	return nil
}
