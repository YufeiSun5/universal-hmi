package desktopservice

import (
	"context"
	"errors"
	"reflect"
	"testing"
)

type fake struct {
	calls []string
	fail  string
}

func (f *fake) call(s string) error {
	f.calls = append(f.calls, s)
	if f.fail == s {
		return errors.New(s)
	}
	return nil
}
func (f *fake) Preflight() error                  { return f.call("check") }
func (f *fake) StartDatabase() error              { return f.call("db-start") }
func (f *fake) StartBackend() error               { return f.call("server-start") }
func (f *fake) WaitBackend(context.Context) error { return f.call("wait") }
func (f *fake) StopBackend() error                { return f.call("server-stop") }
func (f *fake) StopDatabase() error               { return f.call("db-stop") }
func TestLifecycle(t *testing.T) {
	for _, tc := range []struct {
		fail string
		want []string
	}{
		{"", []string{"check", "db-start", "server-start", "wait", "server-stop", "db-stop"}},
		{"check", []string{"check"}},
		{"db-start", []string{"check", "db-start"}},
		{"server-start", []string{"check", "db-start", "server-start", "db-stop"}},
		{"server-stop", []string{"check", "db-start", "server-start", "wait", "server-stop"}},
	} {
		t.Run(tc.fail, func(t *testing.T) {
			f := &fake{fail: tc.fail}
			err := Run(context.Background(), f)
			if (err != nil) != (tc.fail != "") {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(f.calls, tc.want) {
				t.Fatal(f.calls)
			}
		})
	}
}
