package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/YufeiSun5/universal-hmi/backend/internal/rebuild"
)

func fixture(t *testing.T) (string, string, backupManifest) {
	t.Helper()
	parent := t.TempDir()
	root := filepath.Join(parent, "live-project")
	backup := filepath.Join(parent, "backup")
	os.MkdirAll(root, 0700)
	os.MkdirAll(filepath.Join(backup, "project", "data"), 0700)
	file := filepath.Join(backup, "project", "data", "config.json")
	os.WriteFile(file, []byte("original"), 0600)
	h, _ := fileHash(file)
	m := backupManifest{Schema: 1, MigrationID: rebuild.MigrationID, ProjectRoot: root, BackupRoot: backup, Verified: true, Files: map[string]string{"data/config.json": h}}
	return root, filepath.Join(backup, "manifest.json"), m
}
func manifest(t *testing.T, path string, m backupManifest) {
	t.Helper()
	b, _ := json.Marshal(m)
	if e := os.WriteFile(path, b, 0600); e != nil {
		t.Fatal(e)
	}
}
func TestBackupExactSetChecksumAndSafePaths(t *testing.T) {
	for _, test := range []string{"valid", "corrupt", "missing", "extra", "traversal", "absolute", "drive", "identity", "inside", "unverified", "wrong-migration"} {
		t.Run(test, func(t *testing.T) {
			root, path, m := fixture(t)
			switch test {
			case "corrupt":
				os.WriteFile(filepath.Join(m.BackupRoot, "project", "data", "config.json"), []byte("changed"), 0600)
			case "missing":
				os.Remove(filepath.Join(m.BackupRoot, "project", "data", "config.json"))
			case "extra":
				os.WriteFile(filepath.Join(m.BackupRoot, "project", "extra"), []byte("x"), 0600)
			case "traversal":
				m.Files["../escape"] = "0000000000000000000000000000000000000000000000000000000000000000"
			case "absolute":
				m.Files["/escape"] = "0000000000000000000000000000000000000000000000000000000000000000"
			case "drive":
				m.Files["C:/escape"] = "0000000000000000000000000000000000000000000000000000000000000000"
			case "identity":
				m.ProjectRoot = filepath.Dir(root)
			case "inside":
				m.BackupRoot = filepath.Join(root, "backup")
			case "unverified":
				m.Verified = false
			case "wrong-migration":
				m.MigrationID = "other"
			}
			manifest(t, path, m)
			_, e := verifyBackup(root, path)
			if (e == nil) != (test == "valid") {
				t.Fatalf("unexpected safety result %v", e)
			}
		})
	}
}
func TestRejectRedirectedBackupAndWrongDatabase(t *testing.T) {
	root, path, m := fixture(t)
	manifest(t, path, m)
	link := filepath.Join(m.BackupRoot, "project", "link")
	if e := os.Symlink(root, link); e == nil {
		if _, e = verifyBackup(root, path); e == nil {
			t.Fatal("linked backup accepted")
		}
	}
	for _, v := range []struct {
		path, db string
		version  int
	}{{filepath.Join(root, "other"), "universal_hmi", 180006}, {filepath.Join(root, "postgres-data"), "other", 180006}, {filepath.Join(root, "postgres-data"), "universal_hmi", 170000}} {
		if validatePGIdentity(root, v.path, v.db, v.version) == nil {
			t.Fatal("wrong target accepted")
		}
	}
	if e := validatePGIdentity(root, filepath.Join(root, "postgres-data"), "universal_hmi", 180006); e != nil {
		t.Fatal(e)
	}
}
