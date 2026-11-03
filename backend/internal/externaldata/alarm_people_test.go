package externaldata

import (
	"testing"
	"time"
)

func TestConfirmationPacificClock(t *testing.T) {
	zone, err := time.LoadLocation("America/Los_Angeles")
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct{ wall, utc string }{
		{"2026-11-02 07:49:17.000", "2026-11-02T15:49:17Z"},
		{"2026-07-02 07:49:17.123", "2026-07-02T14:49:17.123Z"},
		{"2026-11-01 01:49:17.000", ""},
		{"2026-03-08 02:49:17.000", ""},
	} {
		got, ok := confirmationUTC(tc.wall, zone)
		if ok != (tc.utc != "") || ok && got.Format(time.RFC3339Nano) != tc.utc {
			t.Errorf("%s: %v %v", tc.wall, got, ok)
		}
	}
}
