package server

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"runtime"
)

// LoadAuthFile reads only an operator-provisioned account. It never creates or saves credentials.
// On Unix the file must be owner-only readable/writable. Windows ACLs remain the operator's responsibility.
func LoadAuthFile(filename, publicOrigin string) (*Auth, error) {
	f, err := os.Open(filename)
	if err != nil {
		return nil, fmt.Errorf("open auth file: %w", err)
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return nil, fmt.Errorf("stat auth file: %w", err)
	}
	if !info.Mode().IsRegular() || info.Size() > 4096 {
		return nil, fmt.Errorf("auth file must be a regular file up to 4096 bytes")
	}
	if runtime.GOOS != "windows" && info.Mode().Perm()&0077 != 0 {
		return nil, fmt.Errorf("auth file permissions must exclude group and other access (use mode 0600)")
	}
	var config AuthConfig
	d := json.NewDecoder(io.LimitReader(f, 4097))
	d.DisallowUnknownFields()
	if err := d.Decode(&config); err != nil {
		return nil, fmt.Errorf("invalid auth configuration")
	}
	if d.Decode(new(any)) != io.EOF {
		return nil, fmt.Errorf("auth file must contain exactly one JSON object")
	}
	config.PublicOrigin = publicOrigin
	return NewAuth(config)
}
