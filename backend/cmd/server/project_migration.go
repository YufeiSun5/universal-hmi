package main

import (
	"encoding/json"
	"fmt"
	"github.com/YufeiSun5/universal-hmi/backend/internal/projectmigration"
	"io"
	"os"
)

// This offline local CLI intentionally takes the password on stdin, never in
// process arguments, HTTP requests, shell history or diagnostic output.
func runProjectMigration() error {
	var in struct {
		Action   string `json:"action"`
		Project  string `json:"project"`
		Archive  string `json:"archive"`
		Password string `json:"password"`
		Replace  bool   `json:"replace_existing"`
	}
	d := json.NewDecoder(io.LimitReader(os.Stdin, 16384))
	d.DisallowUnknownFields()
	if d.Decode(&in) != nil || d.Decode(new(any)) != io.EOF {
		return fmt.Errorf("迁移请求格式无效")
	}
	var result projectmigration.Result
	var err error
	switch in.Action {
	case "export":
		result, err = projectmigration.Export(in.Project, in.Archive, in.Password)
	case "import":
		result, err = projectmigration.Import(in.Project, in.Archive, in.Password, in.Replace)
	default:
		return fmt.Errorf("不支持的迁移操作")
	}
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(result)
}
