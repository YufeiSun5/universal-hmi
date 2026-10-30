package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/YufeiSun5/universal-hmi/backend/internal/rebuild"
	"github.com/jackc/pgx/v5"
)

type backupManifest struct {
	Schema      int               `json:"schema"`
	MigrationID string            `json:"migration_id"`
	ProjectRoot string            `json:"project_root"`
	BackupRoot  string            `json:"backup_root"`
	Files       map[string]string `json:"files"`
	Verified    bool              `json:"verified"`
}

func samePath(a, b string) bool {
	a, e := filepath.Abs(a)
	if e != nil {
		return false
	}
	b, e = filepath.Abs(b)
	return e == nil && strings.EqualFold(filepath.Clean(a), filepath.Clean(b))
}
func within(root, path string) bool {
	r, e := filepath.Rel(root, path)
	return e == nil && r != ".." && !strings.HasPrefix(r, ".."+string(os.PathSeparator)) && !filepath.IsAbs(r)
}
func noLinks(path string) error {
	path, e := filepath.Abs(path)
	if e != nil {
		return errors.New("unsafe filesystem path")
	}
	for {
		info, e := os.Lstat(path)
		if e != nil || info.Mode()&os.ModeSymlink != 0 {
			return errors.New("missing or redirected filesystem path")
		}
		parent := filepath.Dir(path)
		if parent == path {
			break
		}
		path = parent
	}
	return nil
}
func fileHash(path string) (string, error) {
	f, e := os.Open(path)
	if e != nil {
		return "", e
	}
	defer f.Close()
	h := sha256.New()
	if _, e = io.Copy(h, f); e != nil {
		return "", e
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}
func verifyBackup(root, path string) (string, error) {
	if e := noLinks(path); e != nil {
		return "", e
	}
	b, e := os.ReadFile(path)
	if e != nil {
		return "", errors.New("backup manifest unavailable")
	}
	var m backupManifest
	if json.Unmarshal(b, &m) != nil || m.Schema != 1 || m.MigrationID != rebuild.MigrationID || !m.Verified || len(m.Files) == 0 {
		return "", errors.New("invalid backup manifest")
	}
	if !samePath(root, m.ProjectRoot) {
		return "", errors.New("backup project identity mismatch")
	}
	backup, e := filepath.Abs(m.BackupRoot)
	if e != nil || within(root, backup) || within(backup, root) {
		return "", errors.New("backup must be separate from project")
	}
	if e = noLinks(backup); e != nil {
		return "", e
	}
	if !samePath(filepath.Dir(path), backup) {
		return "", errors.New("manifest must belong to backup root")
	}
	project := filepath.Join(backup, "project")
	if e = noLinks(project); e != nil {
		return "", e
	}
	expected := map[string]string{}
	for name, digest := range m.Files {
		portable := strings.ReplaceAll(name, "\\", "/")
		if portable == "" || strings.Contains(portable, ":") || strings.HasPrefix(portable, "/") {
			return "", errors.New("unsafe backup member")
		}
		parts := strings.Split(portable, "/")
		for _, part := range parts {
			if part == "" || part == "." || part == ".." {
				return "", errors.New("unsafe backup member")
			}
		}
		if len(digest) != 64 {
			return "", errors.New("invalid backup digest")
		}
		if _, e = hex.DecodeString(digest); e != nil {
			return "", errors.New("invalid backup digest")
		}
		key := strings.ToLower(portable)
		if _, exists := expected[key]; exists {
			return "", errors.New("duplicate backup member")
		}
		expected[key] = strings.ToLower(digest)
	}
	seen := 0
	e = filepath.WalkDir(project, func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return errors.New("backup member unavailable")
		}
		if d.Type()&os.ModeSymlink != 0 {
			return errors.New("redirected backup member")
		}
		if d.IsDir() {
			return nil
		}
		info, e := d.Info()
		if e != nil || !info.Mode().IsRegular() {
			return errors.New("unsupported backup member")
		}
		if e = noLinks(path); e != nil {
			return e
		}
		rel, _ := filepath.Rel(project, path)
		key := strings.ToLower(filepath.ToSlash(rel))
		want, ok := expected[key]
		if !ok {
			return errors.New("unexpected backup member")
		}
		actual, e := fileHash(path)
		if e != nil || actual != want {
			return errors.New("backup member checksum mismatch")
		}
		seen++
		return nil
	})
	if e != nil {
		return "", e
	}
	if seen != len(expected) {
		return "", errors.New("backup member missing")
	}
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:]), nil
}
func validatePGIdentity(root, actual, database string, version int) error {
	if !samePath(filepath.Join(root, "postgres-data"), actual) || database != "universal_hmi" || version < 180000 || version >= 190000 {
		return errors.New("PostgreSQL project identity mismatch")
	}
	return nil
}
func verifyDatabase(root string, pg *pgx.ConnConfig) error {
	if e := noLinks(root); e != nil {
		return e
	}
	if e := noLinks(filepath.Join(root, "postgres-data")); e != nil {
		return e
	}
	statePath := filepath.Join(root, "private-settings.json")
	if e := noLinks(statePath); e != nil {
		return e
	}
	b, e := os.ReadFile(statePath)
	if e != nil {
		return errors.New("private project identity unavailable")
	}
	var state struct {
		Schema   int    `json:"schema"`
		Major    int    `json:"pgMajor"`
		Port     uint16 `json:"pgPort"`
		Password string `json:"adminPassword"`
	}
	if json.Unmarshal(b, &state) != nil || state.Schema != 1 || state.Major != 18 || state.Port == 0 || state.Password == "" || pg.Port != state.Port || pg.Database != "universal_hmi" {
		return errors.New("private project database mismatch")
	}
	for _, fallback := range pg.Fallbacks {
		if fallback.Host != pg.Host || fallback.Port != pg.Port {
			return errors.New("multiple database targets are not allowed")
		}
	}
	admin := pg.Copy()
	admin.User = "hmi_admin"
	admin.Password = state.Password
	connection, e := pgx.ConnectConfig(context.Background(), admin)
	if e != nil {
		return errors.New("cannot verify private PostgreSQL identity")
	}
	defer connection.Close(context.Background())
	var actual, database, version string
	if e = connection.QueryRow(context.Background(), "SELECT current_setting('data_directory'), current_database(), current_setting('server_version_num')").Scan(&actual, &database, &version); e != nil {
		return errors.New("cannot verify private PostgreSQL identity")
	}
	n, e := strconv.Atoi(version)
	if e != nil {
		return errors.New("invalid PostgreSQL version")
	}
	return validatePGIdentity(root, actual, database, n)
}
