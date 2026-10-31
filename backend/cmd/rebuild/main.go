package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"

	"github.com/YufeiSun5/universal-hmi/backend/internal/persistence"
	"github.com/YufeiSun5/universal-hmi/backend/internal/rebuild"
	"github.com/YufeiSun5/universal-hmi/backend/internal/storage"
	"github.com/jackc/pgx/v5"
)

func run() error {
	config := flag.String("database-config", "", "Private PostgreSQL configuration")
	project := flag.String("project-root", "", "Stopped, exclusively held project root")
	migration := flag.String("migration-id", "", "Explicit rebuild identity")
	operation := flag.String("operation", "status", "status, plan or commit")
	manifest := flag.String("backup-manifest", "", "Verified cold-backup manifest")
	token := flag.String("preview-token", "", "Previously reviewed plan token")
	flag.Parse()
	if *migration != rebuild.MigrationID {
		return errors.New("unsupported migration identity")
	}
	if *operation != "status" && *operation != "plan" && *operation != "commit" {
		return errors.New("unsupported operation")
	}
	root, e := filepath.Abs(*project)
	if e != nil || *project == "" {
		return errors.New("project root required")
	}
	info, e := os.Stat(root)
	if e != nil || !info.IsDir() {
		return errors.New("project root unavailable")
	}
	abs, e := filepath.Abs(*config)
	if e != nil || *config == "" {
		return errors.New("database configuration required")
	}
	relative, e := filepath.Rel(root, abs)
	if e != nil || relative == ".." || strings.HasPrefix(relative, ".."+string(os.PathSeparator)) {
		return errors.New("database configuration must belong to project root")
	}
	if e = noLinks(abs); e != nil {
		return e
	}
	dsn, e := persistence.ConfigFile(abs)
	if e != nil {
		return e
	}
	pg, e := pgx.ParseConfig(dsn)
	if e != nil {
		return errors.New("invalid private database configuration")
	}
	ip := net.ParseIP(pg.Host)
	if pg.Host != "localhost" && (ip == nil || !ip.IsLoopback()) {
		return errors.New("offline rebuild only supports local PostgreSQL")
	}
	if e = verifyDatabase(root, pg); e != nil {
		return e
	}
	db, e := persistence.Open("", dsn)
	if e != nil {
		return e
	}
	defer db.Close()
	store := &storage.Store{DB: db}
	// Completed migrations are immutable and do not require old backup paths.
	status, e := rebuild.Run(context.Background(), store, "status", "", "")
	if e != nil {
		return errors.New("cannot inspect rebuild status")
	}
	if status.Status == "already_applied" || *operation == "status" {
		return json.NewEncoder(os.Stdout).Encode(status)
	}
	lease, e := db.Lease(context.Background())
	if e != nil {
		return errors.New("project backend must be stopped before rebuild")
	}
	defer lease.Close()
	digest, e := verifyBackup(root, *manifest)
	if e != nil {
		return e
	}
	out, e := rebuild.Run(context.Background(), store, *operation, digest, *token)
	if e != nil {
		return errors.New("rebuild rejected or transaction rolled back; inspect plan and backup")
	}
	return json.NewEncoder(os.Stdout).Encode(out)
}
func main() {
	if e := run(); e != nil {
		fmt.Fprintln(os.Stderr, e.Error())
		os.Exit(1)
	}
}
