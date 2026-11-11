package projectmigration

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/sys/windows"
)

func TestWindowsShortPathIsNotDirectoryLink(t *testing.T) {
	root := projectFixture(t)
	wide, err := windows.UTF16PtrFromString(root)
	if err != nil {
		t.Fatal(err)
	}
	buf := make([]uint16, 32768)
	n, err := windows.GetShortPathName(wide, &buf[0], uint32(len(buf)))
	if err != nil || n == 0 || n >= uint32(len(buf)) {
		t.Fatalf("short path: %d %v", n, err)
	}
	short := windows.UTF16ToString(buf[:n])
	if strings.EqualFold(short, root) {
		t.Skip("8.3 names are disabled on the temporary volume")
	}
	canonical, err := absoluteRoot(short)
	if err != nil {
		t.Fatal("ordinary short path rejected as a link", err)
	}
	a, _ := os.Stat(root)
	b, err := os.Stat(canonical)
	if err != nil || !os.SameFile(a, b) {
		t.Fatal("short path resolved to another project", err)
	}
	if _, err := Export(root, filepath.Join(short, "inside.hmimigrate"), testPassword); err == nil {
		t.Fatal("short alias bypassed archive-inside-project protection")
	}
}
