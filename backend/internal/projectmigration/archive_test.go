package projectmigration

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const testPassword = "synthetic migration password"

func put(t *testing.T, root, name string, data []byte) {
	t.Helper()
	p := filepath.Join(root, filepath.FromSlash(name))
	if err := os.MkdirAll(filepath.Dir(p), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, data, 0600); err != nil {
		t.Fatal(err)
	}
}
func freePort(t *testing.T) int {
	t.Helper()
	l, e := net.Listen("tcp", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}
func projectFixture(t *testing.T) string {
	t.Helper()
	root := filepath.Join(t.TempDir(), "工程源")
	state, _ := json.Marshal(map[string]any{"schema": 1, "pgMajor": 18, "pgPort": freePort(t), "httpPort": freePort(t), "adminPassword": "existing admin secret", "appPassword": "existing database secret"})
	put(t, root, "private-settings.json", state)
	put(t, root, "postgres-data/PG_VERSION", []byte("18\n"))
	put(t, root, "postgres-data/base/1/100", bytes.Repeat([]byte("existing accounts permissions device approvals data\x00"), 2000))
	put(t, root, "data/database.json", []byte(`{"dsn":"existing database connection"}`))
	put(t, root, "data/security/mfa.key", bytes.Repeat([]byte{0x5a}, 32))
	put(t, root, "data/screens.json", []byte(`{"stable_ids":["A","B"]}`))
	put(t, root, "data/图片/photo.png", []byte("preserved picture"))
	put(t, root, "project.json", []byte(`{"schema":1,"remoteConfig":"remote-access.json"}`))
	put(t, root, "remote-access.json", []byte(`{"schema":2,"enabled":true,"origin":"https://203.0.113.9:9090","certificate":"certs/server.pem","private_key":"certs/key.pem","mobile_enabled":true}`))
	put(t, root, "certs/server.pem", []byte("existing public certificate"))
	put(t, root, "certs/key.pem", []byte("existing private key"))
	put(t, root, "ready.json", []byte(`{"data":"old machine path"}`))
	put(t, root, "service-host.json", []byte(`{"service":"old machine service"}`))
	if e := os.MkdirAll(filepath.Join(root, "postgres-data", "empty"), 0700); e != nil {
		t.Fatal(e)
	}
	return root
}

func TestEncryptedProjectRoundTripRelocationAndBackup(t *testing.T) {
	source := projectFixture(t)
	dest := projectFixture(t)
	archive := filepath.Join(t.TempDir(), "工程.hmimigrate")
	// Public certificates outside the project are included without modifying source.
	external := filepath.Join(t.TempDir(), "original-key.pem")
	if e := os.WriteFile(external, []byte("private key outside project"), 0600); e != nil {
		t.Fatal(e)
	}
	remote, _ := readObject(filepath.Join(source, "remote-access.json"))
	remote["private_key"] = external
	if e := writeObject(filepath.Join(source, "remote-access.json"), remote); e != nil {
		t.Fatal(e)
	}
	snapshot, err := inventory(source)
	if err != nil {
		t.Fatal(err)
	}
	r, err := Export(source, archive, testPassword)
	if err != nil || r.Status != "exported" {
		t.Fatal(r, err)
	}
	raw, _ := os.ReadFile(archive)
	if bytes.Contains(raw, []byte("existing admin secret")) || bytes.Contains(raw, []byte("existing accounts")) {
		t.Fatal("plaintext secrets in export")
	}
	if _, err = Import(dest, archive, testPassword, false); err == nil {
		t.Fatal("overwrote existing without explicit replacement")
	}
	r, err = Import(dest, archive, testPassword, true)
	if err != nil || r.Backup == "" {
		t.Fatal(r, err)
	}
	if _, err = os.Stat(filepath.Join(r.Backup, "service-host.json")); err != nil {
		t.Fatal("old project backup incomplete", err)
	}
	for _, e := range snapshot.Files {
		if e.Directory || strings.HasPrefix(e.Path, "_migration/") || e.Path == "ready.json" || e.Path == "service-host.json" || e.Path == "project.json" {
			continue
		}
		h, n, err := fileHash(filepath.Join(dest, filepath.FromSlash(e.Path)))
		if err != nil || h != e.SHA256 || n != e.Size {
			t.Fatal("changed restored data", e.Path, err)
		}
	}
	project, err := readObject(filepath.Join(dest, "project.json"))
	if err != nil {
		t.Fatal(err)
	}
	remotePath := filepath.Join(dest, filepath.FromSlash(project["remoteConfig"].(string)))
	restored, err := readObject(remotePath)
	if err != nil || restored["origin"] != remote["origin"] {
		t.Fatal("public origin changed", err)
	}
	key, _ := os.ReadFile(filepath.Join(filepath.Dir(remotePath), restored["private_key"].(string)))
	if string(key) != "private key outside project" {
		t.Fatal("public private key changed")
	}
	for _, name := range []string{"ready.json", "service-host.json"} {
		if _, err = os.Stat(filepath.Join(dest, name)); !os.IsNotExist(err) {
			t.Fatal("old machine metadata active", name)
		}
	}
	if _, err = os.Stat(filepath.Join(dest, "postgres-data", "empty")); err != nil {
		t.Fatal("empty PG directory lost")
	}
	// The migrated project remains exportable for another move/backup.
	if _, err = Export(dest, filepath.Join(t.TempDir(), "second.hmimigrate"), testPassword); err != nil {
		t.Fatal(err)
	}
}

func TestBadPasswordCorruptionTruncationPreserveTarget(t *testing.T) {
	source := projectFixture(t)
	dest := projectFixture(t)
	archive := filepath.Join(t.TempDir(), "original.hmimigrate")
	if _, err := Export(source, archive, testPassword); err != nil {
		t.Fatal(err)
	}
	original, _ := os.ReadFile(archive)
	before, _ := inventory(dest)
	for _, kind := range []string{"password", "changed", "truncated", "appended"} {
		t.Run(kind, func(t *testing.T) {
			data := append([]byte(nil), original...)
			password := testPassword
			switch kind {
			case "password":
				password = "not the original password"
			case "changed":
				data[len(data)/2] ^= 0x80
			case "truncated":
				data = data[:len(data)-16]
			case "appended":
				data = append(data, 1)
			}
			file := filepath.Join(t.TempDir(), "bad.hmimigrate")
			if err := os.WriteFile(file, data, 0600); err != nil {
				t.Fatal(err)
			}
			if _, err := Import(dest, file, password, true); err == nil {
				t.Fatal("invalid archive accepted")
			}
			for _, entry := range before.Files {
				if entry.Directory || strings.HasPrefix(entry.Path, "_migration/") {
					continue
				}
				h, _, e := fileHash(filepath.Join(dest, entry.Path))
				if e != nil || h != entry.SHA256 {
					t.Fatal("target changed on failure", entry.Path, e)
				}
			}
		})
	}
}

func TestRejectRunningIncompleteAndUnsafeProjects(t *testing.T) {
	source := projectFixture(t)
	archive := filepath.Join(t.TempDir(), "a.hmimigrate")
	put(t, source, "postgres-data/postmaster.pid", []byte("123"))
	if _, e := Export(source, archive, testPassword); e == nil {
		t.Fatal("running PG accepted")
	}
	os.Remove(filepath.Join(source, "postgres-data/postmaster.pid"))
	if _, e := Export(source, filepath.Join(source, "unsafe.hmimigrate"), testPassword); e == nil {
		t.Fatal("archive inside source accepted")
	}
	os.Remove(filepath.Join(source, "data/security/mfa.key"))
	if _, e := Export(source, archive, testPassword); e == nil {
		t.Fatal("missing security key accepted")
	}
	for _, name := range []string{"../escape", "/root", "C:/escape", "x/../y", "x\\y", "x:ads", "CON.txt", "x/NUL", "x/end.", "x/end ", "x\x00y"} {
		if validName(name) {
			t.Fatal("unsafe archive path", name)
		}
	}
}

func TestAuthenticatedArchiveTraversalAndDuplicateDenied(t *testing.T) {
	for _, names := range [][]string{{"../escape"}, {"data/a", "DATA/A"}} {
		file := filepath.Join(t.TempDir(), "malicious.hmimigrate")
		out, e := os.Create(file)
		if e != nil {
			t.Fatal(e)
		}
		sealed, _ := newSealedWriter(out, testPassword)
		gz := gzip.NewWriter(sealed)
		tw := tar.NewWriter(gz)
		h := sha256.Sum256([]byte("x"))
		m := Manifest{Schema: 1, Platform: "windows-amd64", PostgresMajor: 18}
		for _, name := range names {
			m.Files = append(m.Files, Entry{Path: name, Size: 1, SHA256: hex.EncodeToString(h[:])})
		}
		b, _ := json.Marshal(m)
		tw.WriteHeader(&tar.Header{Name: manifestName, Size: int64(len(b)), Mode: 0600})
		tw.Write(b)
		for _, name := range names {
			tw.WriteHeader(&tar.Header{Name: name, Size: 1, Mode: 0600})
			io.WriteString(tw, "x")
		}
		tw.Close()
		gz.Close()
		sealed.Close()
		out.Close()
		root := filepath.Join(t.TempDir(), "target")
		if _, err := Import(root, file, testPassword, false); err == nil {
			t.Fatal("unsafe authenticated archive accepted")
		}
		if _, err := os.Stat(root); !os.IsNotExist(err) {
			t.Fatal("unsafe archive created target")
		}
	}
}
