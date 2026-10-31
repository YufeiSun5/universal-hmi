package identity

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"io"
	"sync"
	"testing"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/persistence"
)

// A driver barrier makes shutdown overlap an active cleanup query without sleeps.
// It exposes the exact operation context, so canceling in-flight SQL fails even
// on Unix (where unlinking an open database would otherwise conceal the defect).
type auditShutdownConnector struct {
	entered chan context.Context
	release chan struct{}
	closed  chan struct{}
	once    sync.Once
}

func (c *auditShutdownConnector) Connect(context.Context) (driver.Conn, error) {
	return &auditShutdownConn{c: c}, nil
}
func (c *auditShutdownConnector) Driver() driver.Driver { return auditShutdownDriver{c} }

type auditShutdownDriver struct{ c *auditShutdownConnector }

func (d auditShutdownDriver) Open(string) (driver.Conn, error) {
	return &auditShutdownConn{c: d.c}, nil
}

type auditShutdownConn struct{ c *auditShutdownConnector }

func (c *auditShutdownConn) Prepare(string) (driver.Stmt, error) {
	return nil, errors.New("unexpected prepare")
}
func (c *auditShutdownConn) Begin() (driver.Tx, error) {
	return nil, errors.New("unexpected transaction")
}
func (c *auditShutdownConn) Close() error { close(c.c.closed); return nil }
func (c *auditShutdownConn) ExecContext(context.Context, string, []driver.NamedValue) (driver.Result, error) {
	return driver.RowsAffected(0), nil
}
func (c *auditShutdownConn) QueryContext(ctx context.Context, _ string, _ []driver.NamedValue) (driver.Rows, error) {
	c.c.once.Do(func() { c.c.entered <- ctx; <-c.c.release })
	return &auditShutdownRows{}, nil
}

type auditShutdownRows struct{ sent bool }

func (*auditShutdownRows) Columns() []string { return []string{"count"} }
func (*auditShutdownRows) Close() error      { return nil }
func (r *auditShutdownRows) Next(dest []driver.Value) error {
	if r.sent {
		return io.EOF
	}
	r.sent = true
	dest[0] = int64(0)
	return nil
}

func TestPublicAccessAuditShutdownFinishesActiveSQLBeforeDBClose(t *testing.T) {
	connector := &auditShutdownConnector{entered: make(chan context.Context, 1), release: make(chan struct{}), closed: make(chan struct{})}
	db := sql.OpenDB(connector)
	s := &Service{db: &persistence.DB{DB: db}}
	workerCtx, cancel := context.WithCancel(context.Background())
	a := &publicAccessAudit{queue: make(chan PublicAccessEvent, 256), done: make(chan struct{}), cancel: cancel, now: time.Now, maxEvents: 100000, tick: time.Hour, status: PublicAccessAuditStatus{Enabled: true}}
	s.publicAudit = a
	go s.publicAuditWorker(workerCtx, a)
	operationCtx := <-connector.entered
	for i := 0; i < 10; i++ {
		s.RecordPublicAccess(testAccessEvent())
	}
	closeDone := make(chan error, 1)
	go func() { closeDone <- s.Close() }()
	<-workerCtx.Done() // Stop has definitely requested shutdown.
	canceled := operationCtx.Err()
	select {
	case <-connector.closed:
		t.Error("database closed before active SQL finished")
	default:
	}
	close(connector.release)
	if err := <-closeDone; err != nil {
		t.Fatal(err)
	}
	status := s.PublicAccessAuditStatus()
	if status.Dropped != 10 || status.QueueDepth != 0 || status.WriteFailures != 0 {
		t.Fatalf("shutdown drained further work instead of dropping queue: %+v", status)
	}
	if canceled != nil {
		t.Fatalf("shutdown canceled active SQL instead of joining its bounded completion: %v", canceled)
	}
	select {
	case <-a.done:
	default:
		t.Fatal("worker survived Close")
	}
	select {
	case <-connector.closed:
	default:
		t.Fatal("database connection not closed")
	}
}
