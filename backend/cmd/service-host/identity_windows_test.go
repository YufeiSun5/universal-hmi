package main

import "testing"

func TestDatabaseClusterRecordRejectsOtherClusterAndPort(t *testing.T) {
	for _, tc := range []struct {
		record string
		ok     bool
	}{
		{"123\nC:/HMI/project/postgres-data\n100\n55448\n", true},
		{"123\r\nC:\\HMI\\project\\postgres-data\r\n100\r\n55448\r\n", true},
		{"123\nC:/HMI/other/postgres-data\n100\n55448\n", false},
		{"123\nC:/HMI/project/postgres-data\n100\n55449\n", false},
		{"0\nC:/HMI/project/postgres-data\n100\n55448\n", false},
		{"-123\nC:/HMI/project/postgres-data\n100\n55448\n", false},
		{"123\n", false},
	} {
		pid, err := databaseClusterRecord([]byte(tc.record), `C:\HMI\project\postgres-data`, 55448)
		if (err == nil) != tc.ok || tc.ok && pid != 123 {
			t.Fatalf("record %q: pid %d, error %v", tc.record, pid, err)
		}
	}
}
