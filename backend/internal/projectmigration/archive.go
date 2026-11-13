// Package projectmigration owns encrypted, offline Windows project transfer.
// It neither starts services nor connects to external business databases.
package projectmigration

import (
	"archive/tar"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"time"
	"unicode/utf8"
)

const maxFiles = 200000
const maxTotal = int64(1) << 40
const manifestName = "migration-manifest.json"

type Entry struct {
	Path      string `json:"path"`
	Size      int64  `json:"size"`
	SHA256    string `json:"sha256,omitempty"`
	Directory bool   `json:"directory,omitempty"`
	source    string
}
type Manifest struct {
	Schema         int       `json:"schema"`
	Created        time.Time `json:"created"`
	Platform       string    `json:"platform"`
	PostgresMajor  int       `json:"postgres_major"`
	SourceRoot     string    `json:"source_root"`
	Files          []Entry   `json:"files"`
	RemoteIncluded bool      `json:"remote_included"`
}
type Result struct {
	Status string `json:"status"`
	Files  int    `json:"files"`
	Bytes  int64  `json:"bytes"`
	Backup string `json:"previous_project_backup,omitempty"`
	Note   string `json:"note"`
}

func validName(name string) bool {
	if name == "" || len(name) > 1024 || !utf8.ValidString(name) || path.Clean(name) != name || strings.HasPrefix(name, "/") || strings.ContainsAny(name, "\\:\x00") {
		return false
	}
	for _, part := range strings.Split(name, "/") {
		if part == "." || part == ".." || strings.TrimRight(part, " .") != part || strings.ContainsAny(part, "<>\"|?*") {
			return false
		}
		base := strings.ToUpper(strings.SplitN(part, ".", 2)[0])
		if base == "CON" || base == "PRN" || base == "AUX" || base == "NUL" || base == "CONIN$" || base == "CONOUT$" || len(base) == 4 && (strings.HasPrefix(base, "COM") || strings.HasPrefix(base, "LPT")) && base[3] >= '0' && base[3] <= '9' {
			return false
		}
		for _, r := range part {
			if r < 32 {
				return false
			}
		}
	}
	return true
}
func absoluteRoot(root string) (string, error) {
	abs, err := filepath.Abs(root)
	if err != nil {
		return "", err
	}
	if filepath.Dir(abs) == abs {
		return "", errors.New("不能将磁盘根目录作为工程目录")
	}
	// EvalSymlinks also expands Windows 8.3 names. A spelling difference is
	// not evidence of a link: inspect each existing ancestor before resolving.
	for current := filepath.Dir(abs); ; current = filepath.Dir(current) {
		info, e := os.Lstat(current)
		if e != nil {
			return "", e
		}
		if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return "", errors.New("工程父目录不能通过链接或联接跳转")
		}
		if filepath.Dir(current) == current {
			break
		}
	}
	if info, err := os.Lstat(abs); err == nil && (!info.IsDir() || info.Mode()&os.ModeSymlink != 0) {
		return "", errors.New("工程目录必须是普通目录")
	}
	return canonicalFile(abs)
}

// Resolve existing aliases for containment checks, including an existing final
// directory's short name. New archive/target names retain their chosen spelling.
func canonicalFile(file string) (string, error) {
	abs, err := filepath.Abs(file)
	if err != nil {
		return "", err
	}
	if _, err = os.Lstat(abs); err == nil {
		return filepath.EvalSymlinks(abs)
	} else if !os.IsNotExist(err) {
		return "", err
	}
	parent, err := filepath.EvalSymlinks(filepath.Dir(abs))
	if err != nil {
		return "", err
	}
	return filepath.Join(parent, filepath.Base(abs)), nil
}
func contained(root, file string) bool {
	rel, err := filepath.Rel(root, file)
	return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) && !filepath.IsAbs(rel)
}
func fileHash(file string) (string, int64, error) {
	f, err := os.Open(file)
	if err != nil {
		return "", 0, err
	}
	defer f.Close()
	h := sha256.New()
	n, err := io.Copy(h, f)
	return hex.EncodeToString(h.Sum(nil)), n, err
}
func readObject(file string) (map[string]any, error) {
	f, err := os.Open(file)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, 1024*1024+1))
	if err != nil || len(b) > 1024*1024 {
		return nil, errors.New("工程配置文件超限")
	}
	b = []byte(strings.TrimPrefix(string(b), "\ufeff"))
	var obj map[string]any
	if json.Unmarshal(b, &obj) != nil || obj == nil {
		return nil, errors.New("工程配置格式无效")
	}
	return obj, nil
}
func writeObject(file string, obj any) error {
	b, err := json.MarshalIndent(obj, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(file, append(b, '\n'), 0600)
}

// Export requires a stopped bundled PG18 project. The Windows wrapper owns the
// launcher's management mutex throughout this operation and rejects open clients.
func validateProject(root string, checkPorts bool) error {
	state, err := readObject(filepath.Join(root, "private-settings.json"))
	if err != nil {
		return errors.New("缺少完整工程 private-settings.json，请选择安装版工程根目录")
	}
	if state["schema"] != float64(1) || state["pgMajor"] != float64(18) {
		return errors.New("仅支持当前Windows完整安装版的PostgreSQL 18工程")
	}
	version, err := os.ReadFile(filepath.Join(root, "postgres-data", "PG_VERSION"))
	if err != nil || strings.TrimSpace(string(version)) != "18" {
		return errors.New("工程数据库版本或目录不完整")
	}
	for _, name := range []string{"data/database.json", "data/security/mfa.key", "project.json"} {
		if info, e := os.Stat(filepath.Join(root, filepath.FromSlash(name))); e != nil || !info.Mode().IsRegular() {
			return fmt.Errorf("工程缺少必要文件：%s", name)
		}
	}
	if _, err := os.Lstat(filepath.Join(root, "postgres-data", "postmaster.pid")); !os.IsNotExist(err) {
		return errors.New("数据库仍在运行或停止未确认，请通过原安装版停止后台后重试")
	}
	if checkPorts {
		for _, field := range []string{"pgPort", "httpPort"} {
			port, ok := state[field].(float64)
			if !ok || port < 1 || port > 65535 || port != float64(int(port)) {
				return errors.New("工程端口配置无效")
			}
			conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", int(port)), 300*time.Millisecond)
			if err == nil {
				conn.Close()
				return errors.New("工程端口仍被占用，请先停止后台和数据库")
			}
		}
	}
	return nil
}

func inventory(root string) (Manifest, error) {
	m := Manifest{Schema: 1, Created: time.Now().UTC(), Platform: "windows-amd64", PostgresMajor: 18, SourceRoot: root}
	err := filepath.WalkDir(root, func(file string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if file == root {
			return nil
		}
		name, _ := filepath.Rel(root, file)
		name = filepath.ToSlash(name)
		if !validName(name) || name == manifestName || strings.HasPrefix(name, "_migration/") || name == "_migration" {
			return fmt.Errorf("不支持的工程路径：%s", name)
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink != 0 || (!info.IsDir() && !info.Mode().IsRegular()) {
			return fmt.Errorf("不能迁移链接或特殊文件：%s", name)
		}
		entry := Entry{Path: name, Directory: d.IsDir(), source: file}
		if !entry.Directory {
			entry.SHA256, entry.Size, err = fileHash(file)
			if err != nil {
				return err
			}
		}
		m.Files = append(m.Files, entry)
		if len(m.Files) > maxFiles {
			return errors.New("工程文件数量超限")
		}
		return nil
	})
	if err != nil {
		return m, err
	}
	// Capture referenced public TLS material even when it resides outside project.
	project, err := readObject(filepath.Join(root, "project.json"))
	if err != nil {
		return m, err
	}
	remoteName, _ := project["remoteConfig"].(string)
	if remoteName != "" {
		if !filepath.IsAbs(remoteName) {
			remoteName = filepath.Join(root, remoteName)
		}
		remote, err := readObject(remoteName)
		if err != nil {
			return m, errors.New("公网配置无法读取，未导出不完整迁移包")
		}
		add := func(name, source string) error {
			info, e := os.Lstat(source)
			if e != nil || !info.Mode().IsRegular() {
				return fmt.Errorf("无法读取公网证书或配置：%s", name)
			}
			h, n, e := fileHash(source)
			if e != nil {
				return e
			}
			if n > 1024*1024 {
				return errors.New("公网证书或配置文件超限")
			}
			m.Files = append(m.Files, Entry{Path: name, Size: n, SHA256: h, source: source})
			return nil
		}
		if err = add("_migration/remote-access.json", remoteName); err != nil {
			return m, err
		}
		m.RemoteIncluded = true
		for _, field := range []string{"certificate", "private_key"} {
			name, _ := remote[field].(string)
			if name == "" {
				if remote["enabled"] == true {
					return m, errors.New("已启用公网配置缺少证书或私钥")
				}
				continue
			}
			if !filepath.IsAbs(name) {
				name = filepath.Join(filepath.Dir(remoteName), name)
			}
			if _, e := os.Stat(name); os.IsNotExist(e) && remote["enabled"] != true {
				continue
			}
			if err = add("_migration/"+field+".pem", name); err != nil {
				return m, err
			}
		}
	}
	sort.Slice(m.Files, func(i, j int) bool { return m.Files[i].Path < m.Files[j].Path })
	return m, nil
}

func Export(root, archive, password string) (Result, error) {
	var result Result
	if utf8.RuneCountInString(password) < 10 || len(password) > 1024 {
		return result, errors.New("迁移密码需至少10个字符，最长1024字节")
	}
	root, err := absoluteRoot(root)
	if err != nil {
		return result, err
	}
	archive, err = canonicalFile(archive)
	if err != nil {
		return result, err
	}
	if contained(root, archive) {
		return result, errors.New("迁移包必须保存在工程目录之外")
	}
	if _, err = os.Lstat(archive); !os.IsNotExist(err) {
		return result, errors.New("目标文件已存在，请选择新文件名")
	}
	if err = validateProject(root, true); err != nil {
		return result, err
	}
	m, err := inventory(root)
	if err != nil {
		return result, err
	}
	temp, err := os.CreateTemp(filepath.Dir(archive), ".hmi-export-*")
	if err != nil {
		return result, err
	}
	defer os.Remove(temp.Name())
	defer temp.Close()
	sealed, err := newSealedWriter(temp, password)
	if err != nil {
		return result, err
	}
	gz := gzip.NewWriter(sealed)
	tw := tar.NewWriter(gz)
	metadata, err := json.Marshal(m)
	if err != nil {
		return result, err
	}
	if len(metadata) > 32*1024*1024 {
		return result, errors.New("迁移目录超限")
	}
	if err = tw.WriteHeader(&tar.Header{Name: manifestName, Mode: 0600, Size: int64(len(metadata))}); err != nil {
		return result, err
	}
	if _, err = tw.Write(metadata); err != nil {
		return result, err
	}
	for _, entry := range m.Files {
		header := &tar.Header{Name: entry.Path, Mode: 0600, Size: entry.Size, Typeflag: tar.TypeReg}
		if entry.Directory {
			header.Typeflag = tar.TypeDir
			header.Mode = 0700
		}
		if err = tw.WriteHeader(header); err != nil {
			return result, err
		}
		if entry.Directory {
			continue
		}
		file, e := os.Open(entry.source)
		if e != nil {
			return result, e
		}
		h := sha256.New()
		n, e := io.Copy(io.MultiWriter(tw, h), file)
		closeErr := file.Close()
		if e != nil {
			return result, e
		}
		if closeErr != nil {
			return result, closeErr
		}
		if n != entry.Size || hex.EncodeToString(h.Sum(nil)) != entry.SHA256 {
			return result, errors.New("导出期间工程发生变化，请停止全部入口后重试")
		}
		result.Files++
		result.Bytes += n
		if result.Bytes > maxTotal {
			return result, errors.New("工程数据量超限")
		}
	}
	if err = validateProject(root, true); err != nil {
		return result, err
	}
	for _, close := range []func() error{tw.Close, gz.Close, sealed.Close, temp.Sync, temp.Close} {
		if err = close(); err != nil {
			return result, err
		}
	}
	if _, err = os.Lstat(archive); !os.IsNotExist(err) {
		return result, errors.New("目标文件已存在")
	}
	if err = os.Rename(temp.Name(), archive); err != nil {
		return result, err
	}
	result.Status = "exported"
	result.Note = "完整工程已加密导出。旧后台保持停止；请妥善保管迁移密码。"
	return result, nil
}

func Import(root, archive, password string, replace bool) (Result, error) {
	var result Result
	root, err := absoluteRoot(root)
	if err != nil {
		return result, err
	}
	archive, err = canonicalFile(archive)
	if err != nil {
		return result, err
	}
	if contained(root, archive) {
		return result, errors.New("请将迁移包放在目标工程目录之外")
	}
	emptyTarget := false
	if _, err = os.Stat(root); err == nil {
		children, e := os.ReadDir(root)
		if e != nil {
			return result, e
		}
		emptyTarget = len(children) == 0
		if !replace && !emptyTarget {
			return result, errors.New("目标工程已存在，需要明确选择备份后替换")
		}
		if !emptyTarget {
			if err = validateProject(root, true); err != nil {
				return result, err
			}
		}
	} else if !os.IsNotExist(err) {
		return result, err
	}
	input, err := os.Open(archive)
	if err != nil {
		return result, err
	}
	defer input.Close()
	reader, err := newSealedReader(input, password)
	if err != nil {
		return result, err
	}
	gz, err := gzip.NewReader(reader)
	if err != nil {
		return result, errArchive
	}
	defer gz.Close()
	tr := tar.NewReader(gz)
	header, err := tr.Next()
	if err != nil || header.Name != manifestName || header.Typeflag != tar.TypeReg || header.Size > 32*1024*1024 {
		return result, errArchive
	}
	var m Manifest
	if json.NewDecoder(tr).Decode(&m) != nil || m.Schema != 1 || m.Platform != "windows-amd64" || m.PostgresMajor != 18 || len(m.Files) == 0 || len(m.Files) > maxFiles {
		return result, errArchive
	}
	expected := map[string]Entry{}
	total := int64(0)
	for _, entry := range m.Files {
		if !validName(entry.Path) || entry.Path == manifestName || entry.Size < 0 || entry.Size > maxTotal || entry.Directory && entry.Size != 0 {
			return result, errArchive
		}
		if _, ok := expected[strings.ToLower(entry.Path)]; ok {
			return result, errArchive
		}
		if !entry.Directory {
			if b, e := hex.DecodeString(entry.SHA256); e != nil || len(b) != 32 {
				return result, errArchive
			}
		}
		expected[strings.ToLower(entry.Path)] = entry
		total += entry.Size
		if total > maxTotal {
			return result, errArchive
		}
	}
	stage, err := os.MkdirTemp(filepath.Dir(root), ".hmi-import-*")
	if err != nil {
		return result, err
	}
	defer os.RemoveAll(stage) // only the exact fresh sibling returned by MkdirTemp
	if err = protectDirectory(stage); err != nil {
		return result, err
	}
	for {
		header, err = tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return result, errArchive
		}
		entry, ok := expected[strings.ToLower(header.Name)]
		if !ok || header.Name != entry.Path || header.Size != entry.Size {
			return result, errArchive
		}
		delete(expected, strings.ToLower(header.Name))
		file := filepath.Join(stage, filepath.FromSlash(entry.Path))
		if !contained(stage, file) {
			return result, errArchive
		}
		if entry.Directory {
			if header.Typeflag != tar.TypeDir {
				return result, errArchive
			}
			if err = os.MkdirAll(file, 0700); err != nil {
				return result, err
			}
			continue
		}
		if header.Typeflag != tar.TypeReg {
			return result, errArchive
		}
		if err = os.MkdirAll(filepath.Dir(file), 0700); err != nil {
			return result, err
		}
		out, e := os.OpenFile(file, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
		if e != nil {
			return result, e
		}
		h := sha256.New()
		n, e := io.Copy(io.MultiWriter(out, h), tr)
		closeErr := out.Close()
		if e != nil || closeErr != nil || n != entry.Size || hex.EncodeToString(h.Sum(nil)) != entry.SHA256 {
			return result, errArchive
		}
		result.Files++
		result.Bytes += n
	}
	if len(expected) != 0 {
		return result, errArchive
	}
	if extra, e := io.ReadAll(io.LimitReader(gz, 1)); e != nil || len(extra) != 0 || !reader.done {
		return result, errArchive
	}
	if err = validateProject(stage, false); err != nil {
		return result, err
	}
	if err = relocate(stage, m); err != nil {
		return result, err
	}
	if _, err = os.Stat(root); err == nil {
		if emptyTarget {
			if err = os.Remove(root); err != nil {
				return result, errors.New("目标空目录已发生变化，未替换")
			}
		} else {
			if err = validateProject(root, true); err != nil {
				return result, err
			}
			backup, e := os.MkdirTemp(filepath.Dir(root), filepath.Base(root)+"-before-migration-*")
			if e != nil {
				return result, e
			}
			if e = os.Remove(backup); e != nil {
				return result, e
			}
			if e = os.Rename(root, backup); e != nil {
				return result, e
			}
			result.Backup = backup
		}
	}
	if err = os.Rename(stage, root); err != nil {
		if result.Backup != "" {
			if restoreErr := os.Rename(result.Backup, root); restoreErr != nil {
				return result, fmt.Errorf("导入切换失败；原工程保留于 %s", result.Backup)
			}
		}
		return result, err
	}
	result.Status = "imported"
	result.Note = "工程和用户授权已恢复，后台尚未启动。请在新服务器打开本机开发端，检查内网地址；公网地址与原证书保持。"
	return result, nil
}

func relocate(stage string, m Manifest) error {
	// Keep original deployment metadata for review, but never adopt old PID,
	// service-registration or executable paths on another Windows machine.
	archive := filepath.Join(stage, "migration-original-"+time.Now().UTC().Format("20060102T150405.000000000"))
	if err := os.Mkdir(archive, 0700); err != nil {
		return err
	}
	for _, name := range []string{"ready.json", "service-host.json", "project.json", "backend-operation.json", "postgres-data/postmaster.opts"} {
		file := filepath.Join(stage, filepath.FromSlash(name))
		if _, err := os.Stat(file); os.IsNotExist(err) {
			continue
		} else if err != nil {
			return err
		}
		if err := os.Rename(file, filepath.Join(archive, strings.ReplaceAll(name, "/", "-"))); err != nil {
			return err
		}
	}
	project := map[string]any{"schema": 1}
	if m.RemoteIncluded {
		remoteFile := filepath.Join(stage, "_migration", "remote-access.json")
		remote, err := readObject(remoteFile)
		if err != nil {
			return err
		}
		for _, field := range []string{"certificate", "private_key"} {
			if _, err := os.Stat(filepath.Join(stage, "_migration", field+".pem")); err == nil {
				remote[field] = field + ".pem"
			} else if remote["enabled"] == true {
				return errors.New("迁移包缺少原公网证书或私钥")
			}
		}
		if err = writeObject(remoteFile, remote); err != nil {
			return err
		}
		// A reserved transfer directory must not remain in an exported project.
		dest := "migrated-public-" + time.Now().UTC().Format("20060102T150405.000000000")
		if err = os.Rename(filepath.Join(stage, "_migration"), filepath.Join(stage, dest)); err != nil {
			return err
		}
		project["remoteConfig"] = dest + "/remote-access.json"
	}
	return writeObject(filepath.Join(stage, "project.json"), project)
}
