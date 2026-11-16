package objectstore

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

func TestImmutableFilesIntegrityAndConcurrentDeduplication(t *testing.T) {
	dir := t.TempDir()
	s, e := Open(dir)
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close()
	data := bytes.Repeat([]byte("image payload"), 200)
	ctx := context.Background()
	var wg sync.WaitGroup
	for range 8 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			ref, e := s.Put(ctx, data)
			if e != nil {
				t.Error(e)
				return
			}
			got, e := s.Get(ctx, ref)
			if e != nil || !bytes.Equal(got, data) {
				t.Errorf("readback: %v", e)
			}
		}()
	}
	wg.Wait()
	ref, e := s.Put(ctx, data)
	if e != nil {
		t.Fatal(e)
	}
	r, e := Parse(ref)
	if e != nil {
		t.Fatal(e)
	}
	n := 0
	filepath.WalkDir(dir, func(_ string, d os.DirEntry, e error) error {
		if e != nil {
			return e
		}
		if !d.IsDir() {
			n++
		}
		return nil
	})
	if n != 1 {
		t.Fatalf("expected one immutable object, got %d", n)
	}
	if e = os.WriteFile(filepath.Join(dir, filepath.FromSlash(r.Key)), []byte("corrupt"), 0600); e != nil {
		t.Fatal(e)
	}
	if _, e = s.Get(ctx, ref); e == nil {
		t.Fatal("corruption hidden")
	}
	if _, e = s.Put(ctx, data); e == nil {
		t.Fatal("silently overwrote corrupt object")
	}
	r.Key = "../../outside"
	bad, _ := json.Marshal(r)
	if _, e = s.Get(ctx, bad); e == nil {
		t.Fatal("traversal accepted")
	}
	os.Remove(filepath.Join(dir, filepath.FromSlash("sha256/"+r.SHA256[:2]+"/"+r.SHA256)))
	if _, e = s.Get(ctx, ref); e == nil {
		t.Fatal("missing object accepted")
	}
}

func TestInterruptedWriteCannotCommitReference(t *testing.T) {
	s, e := Open(t.TempDir())
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, e = s.Put(ctx, []byte("new image")); e == nil {
		t.Fatal("cancelled write succeeded")
	}
	ref, e := s.Put(context.Background(), []byte("new image"))
	if e != nil {
		t.Fatal(e)
	}
	if _, e = s.Get(context.Background(), ref); e != nil {
		t.Fatal(e)
	}
}
