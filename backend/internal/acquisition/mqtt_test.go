package acquisition

import (
	"testing"
	"time"
)

func TestPackedKepStationsQualityAndIdentity(t *testing.T) {
	rows, err := Decode("source", "packed", "kep", []byte(`{"values":[{"id":"IO01.temp","v":20,"q":true,"t":1700000000000},{"id":"IO02.temp","v":30,"q":false,"t":1700000000000},{"id":"IO03.temp","v":40,"t":1700000000000}]}`))
	if err != nil || len(rows) != 3 {
		t.Fatalf("%v %+v", err, rows)
	}
	if rows[0].Path == rows[1].Path || rows[0].Quality != "good" || rows[1].Quality != "bad" || rows[2].Quality != "bad" {
		t.Fatalf("%+v", rows)
	}
	if !rows[0].Time.Equal(time.UnixMilli(1700000000000)) {
		t.Fatal("wrong timestamp")
	}
}
func TestGenericMissingSourceTimeRejected(t *testing.T) {
	if _, err := Decode("s", "t", "generic", []byte(`{"points":[{"path":"p","value":1,"quality":"good"}]}`)); err == nil {
		t.Fatal("missing source time accepted")
	}
}
