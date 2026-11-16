// Package objectstore adapts Go CDK's local blob driver to immutable project files.
// Business permissions and database references remain owned by their modules.
package objectstore

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"regexp"

	"gocloud.dev/blob"
	"gocloud.dev/blob/fileblob"
	"gocloud.dev/gcerrors"
	"golang.org/x/sync/singleflight"
)

const MaxBytes = 32 * 1024 * 1024
const format = "fileblob-v1"

type Reference struct {
	Storage string `json:"storage"`
	Key     string `json:"key"`
	SHA256  string `json:"sha256"`
	Size    int64  `json:"size"`
}

type Store struct {
	bucket *blob.Bucket
	writes singleflight.Group
}

func Open(dir string) (*Store, error) {
	abs, err := filepath.Abs(dir)
	if err != nil {
		return nil, err
	}
	b, err := fileblob.OpenBucket(abs, &fileblob.Options{CreateDir: true, DirFileMode: 0700, NoTempDir: true, Metadata: fileblob.MetadataDontWrite})
	if err != nil {
		return nil, err
	}
	return &Store{bucket: b}, nil
}

func (s *Store) Close() error { return s.bucket.Close() }

var digestPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

func Parse(data []byte) (Reference, error) {
	var r Reference
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&r); err != nil {
		return r, errors.New("invalid project file reference")
	}
	if dec.Decode(new(any)) != io.EOF || r.Storage != format || !digestPattern.MatchString(r.SHA256) || r.Key != "sha256/"+r.SHA256[:2]+"/"+r.SHA256 || r.Size <= 0 || r.Size > MaxBytes {
		return r, errors.New("invalid project file reference")
	}
	return r, nil
}

func IsReference(data []byte) bool { return len(data) > 0 && data[0] == '{' }

// Put finishes and verifies the file before a caller commits its database reference.
// Identical content shares one immutable object. Failed DB writes may leave an
// unreferenced file; deleting it here could break another committed reference.
func (s *Store) Put(ctx context.Context, data []byte) ([]byte, error) {
	if s == nil || len(data) == 0 || len(data) > MaxBytes {
		return nil, errors.New("invalid project file size or store")
	}
	digest := sha256.Sum256(data)
	hash := hex.EncodeToString(digest[:])
	r := Reference{Storage: format, Key: "sha256/" + hash[:2] + "/" + hash, SHA256: hash, Size: int64(len(data))}
	// The project has one Store and one backend lease. Coalesce equal uploads
	// before entering the file driver, including its Windows rename boundary.
	result, err, _ := s.writes.Do(hash, func() (any, error) {
		_, err := s.bucket.Attributes(ctx, r.Key)
		if gcerrors.Code(err) == gcerrors.NotFound {
			if err = s.bucket.WriteAll(ctx, r.Key, data, &blob.WriterOptions{IfNotExist: true}); err != nil {
				// Another writer may have committed this identical immutable object.
				// Windows can refuse its replacement while a reader has it open.
				encoded, _ := json.Marshal(r)
				if _, readErr := s.Get(ctx, encoded); readErr != nil {
					return nil, fmt.Errorf("write project file: %w", err)
				}
			}
		} else if err != nil {
			return nil, err
		}
		encoded, _ := json.Marshal(r)
		if _, err = s.Get(ctx, encoded); err != nil {
			return nil, err
		}
		return encoded, nil
	})
	if err != nil {
		return nil, err
	}
	return bytes.Clone(result.([]byte)), nil
}

func (s *Store) Get(ctx context.Context, encoded []byte) ([]byte, error) {
	if s == nil {
		return nil, errors.New("project file store is required")
	}
	r, err := Parse(encoded)
	if err != nil {
		return nil, err
	}
	reader, err := s.bucket.NewReader(ctx, r.Key, nil)
	if err != nil {
		return nil, fmt.Errorf("read project file %s: %w", r.SHA256, err)
	}
	defer reader.Close()
	data, err := io.ReadAll(io.LimitReader(reader, r.Size+1))
	if err != nil {
		return nil, err
	}
	hash := sha256.Sum256(data)
	if int64(len(data)) != r.Size || hex.EncodeToString(hash[:]) != r.SHA256 {
		return nil, fmt.Errorf("project file checksum mismatch: %s", r.SHA256)
	}
	return data, nil
}
