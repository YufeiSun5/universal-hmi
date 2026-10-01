package analysis

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/csv"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
	"github.com/YufeiSun5/universal-hmi/backend/internal/storage"
	"github.com/xuri/excelize/v2"
)

type Mapping struct {
	SessionID   string `json:"session_id"`
	Sheet       string `json:"sheet"`
	TimeColumn  int    `json:"time_column"`
	ValueColumn int    `json:"value_column"`
	Header      bool   `json:"header"`
	Station     string `json:"station"`
	Name        string `json:"name"`
	Unit        string `json:"unit"`
}
type ImportRow struct {
	Row   int       `json:"row"`
	Time  time.Time `json:"time"`
	Value float64   `json:"value"`
}
type Preview struct {
	Rows   []ImportRow `json:"rows"`
	Errors []string    `json:"errors"`
	Count  int         `json:"count"`
}
type session struct {
	Data map[string][][]string
	At   time.Time
}
type Job struct {
	ID      string    `json:"id"`
	State   string    `json:"state"`
	Format  string    `json:"format"`
	Rows    int       `json:"rows"`
	Message string    `json:"message"`
	At      time.Time `json:"at"`
}
type exportTask struct {
	ID     string
	Filter storage.Filter
	Format string
}
type Service struct {
	mu       sync.Mutex
	store    *storage.Store
	points   *points.Service
	dir      string
	sessions map[string]session
	jobs     map[string]Job
	queue    chan exportTask
	stop     chan struct{}
	done     chan struct{}
}

func ID(prefix string) string {
	var b [12]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	return prefix + hex.EncodeToString(b[:])
}
func New(db *storage.Store, ps *points.Service, dir string) (*Service, error) {
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	s := &Service{store: db, points: ps, dir: dir, sessions: map[string]session{}, jobs: map[string]Job{}, queue: make(chan exportTask, 8), stop: make(chan struct{}), done: make(chan struct{})}
	var previous []Job
	if err := db.LoadConfig("jobs", &previous); err != nil {
		return nil, err
	}
	for _, j := range previous {
		if j.State == "queued" || j.State == "running" {
			j.State = "failed"
			j.Message = "interrupted by restart; enqueue again"
		}
		s.jobs[j.ID] = j
	}
	go s.loop()
	return s, nil
}
func (s *Service) Close() { close(s.stop); <-s.done }
func (s *Service) Upload(r io.Reader, filename string) (map[string]any, error) {
	data := map[string][][]string{}
	if strings.HasSuffix(strings.ToLower(filename), ".csv") {
		cr := csv.NewReader(io.LimitReader(r, 8*1024*1024+1))
		cr.FieldsPerRecord = -1
		rows := [][]string{}
		for len(rows) <= 50000 {
			row, err := cr.Read()
			if err == io.EOF {
				break
			}
			if err != nil {
				return nil, err
			}
			if len(row) > 100 {
				return nil, fmt.Errorf("column limit 100")
			}
			rows = append(rows, row)
		}
		if len(rows) > 50000 {
			return nil, fmt.Errorf("row limit 50000")
		}
		data["CSV"] = rows
	} else if strings.HasSuffix(strings.ToLower(filename), ".xlsx") {
		book, err := excelize.OpenReader(io.LimitReader(r, 8*1024*1024+1), excelize.Options{UnzipSizeLimit: 32 * 1024 * 1024, UnzipXMLSizeLimit: 8 * 1024 * 1024})
		if err != nil {
			return nil, err
		}
		defer book.Close()
		sheets := book.GetSheetList()
		if len(sheets) > 16 {
			return nil, fmt.Errorf("sheet limit 16")
		}
		total := 0
		for _, sheet := range sheets {
			iterator, err := book.Rows(sheet)
			if err != nil {
				return nil, err
			}
			rows := [][]string{}
			for iterator.Next() {
				cells, err := iterator.Columns(excelize.Options{RawCellValue: true})
				if err != nil {
					iterator.Close()
					return nil, err
				}
				if len(cells) > 100 {
					iterator.Close()
					return nil, fmt.Errorf("column limit 100")
				}
				rows = append(rows, cells)
				total++
				if total > 50000 {
					iterator.Close()
					return nil, fmt.Errorf("row limit 50000")
				}
			}
			err = iterator.Error()
			iterator.Close()
			if err != nil {
				return nil, err
			}
			data[sheet] = rows
		}
	} else {
		return nil, fmt.Errorf("only .csv and .xlsx supported")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for id, session := range s.sessions {
		if time.Since(session.At) > 30*time.Minute {
			delete(s.sessions, id)
		}
	}
	if len(s.sessions) >= 8 {
		return nil, fmt.Errorf("import sessions full; retry in 30 minutes")
	}
	id := ID("import_")
	s.sessions[id] = session{data, time.Now()}
	sheets := []map[string]any{}
	for name, rows := range data {
		preview := rows
		if len(preview) > 8 {
			preview = preview[:8]
		}
		sheets = append(sheets, map[string]any{"name": name, "rows": len(rows), "preview": preview})
	}
	return map[string]any{"session_id": id, "sheets": sheets}, nil
}
func ParseTime(text string) (time.Time, error) {
	for _, layout := range []string{time.RFC3339Nano, "2006-01-02 15:04:05", "2006/01/02 15:04:05", "2006-01-02", "01-02-06"} {
		if t, err := time.Parse(layout, strings.TrimSpace(text)); err == nil {
			return t.UTC(), nil
		}
	}
	number, err := strconv.ParseFloat(text, 64)
	if err == nil && !math.IsNaN(number) && !math.IsInf(number, 0) {
		if number > 1e12 && number < 4e12 {
			return time.UnixMilli(int64(number)).UTC(), nil
		}
		if number > 1e9 && number < 4e9 {
			return time.Unix(int64(number), 0).UTC(), nil
		}
		if number > 20000 && number < 100000 {
			return time.Date(1899, 12, 30, 0, 0, 0, 0, time.UTC).Add(time.Duration(number*86400) * time.Second), nil
		}
	}
	return time.Time{}, fmt.Errorf("expected ISO time, UTC date/time, Unix epoch or Excel serial")
}
func (s *Service) Preview(m Mapping, all bool) (Preview, error) {
	s.mu.Lock()
	item, ok := s.sessions[m.SessionID]
	s.mu.Unlock()
	if !ok || time.Since(item.At) > 30*time.Minute {
		return Preview{}, fmt.Errorf("import session expired")
	}
	rows, ok := item.Data[m.Sheet]
	if !ok || m.TimeColumn < 0 || m.TimeColumn > 99 || m.ValueColumn < 0 || m.ValueColumn > 99 || m.TimeColumn == m.ValueColumn {
		return Preview{}, fmt.Errorf("invalid sheet/column mapping")
	}
	result := Preview{Rows: []ImportRow{}, Errors: []string{}}
	for i, row := range rows {
		if i == 0 && m.Header {
			continue
		}
		if m.TimeColumn >= len(row) || m.ValueColumn >= len(row) {
			if len(result.Errors) < 20 {
				result.Errors = append(result.Errors, fmt.Sprintf("row %d: missing column", i+1))
			}
			continue
		}
		at, err := ParseTime(row[m.TimeColumn])
		if err != nil {
			if len(result.Errors) < 20 {
				result.Errors = append(result.Errors, fmt.Sprintf("row %d: %v", i+1, err))
			}
			continue
		}
		value, err := strconv.ParseFloat(strings.TrimSpace(row[m.ValueColumn]), 64)
		if err != nil || math.IsNaN(value) || math.IsInf(value, 0) {
			if len(result.Errors) < 20 {
				result.Errors = append(result.Errors, fmt.Sprintf("row %d: invalid numeric value", i+1))
			}
			continue
		}
		result.Count++
		if all || len(result.Rows) < 100 {
			result.Rows = append(result.Rows, ImportRow{i + 1, at, value})
		}
	}
	return result, nil
}
func (s *Service) Import(ctx context.Context, m Mapping) (map[string]any, error) {
	encoded, _ := json.Marshal(m)
	hash := sha256.Sum256(encoded)
	key := fmt.Sprintf("import:%x", hash[:])
	var previous map[string]any
	if err := s.store.LoadConfig(key, &previous); err != nil {
		return nil, err
	}
	if previous != nil {
		return previous, nil
	}
	preview, err := s.Preview(m, true)
	if err != nil {
		return nil, err
	}
	if len(preview.Errors) > 0 {
		return nil, fmt.Errorf("fix invalid rows before import")
	}
	if preview.Count == 0 {
		return nil, fmt.Errorf("no valid rows")
	}
	// Dedicated history-only identity; imported rows never masquerade as live source samples.
	id := ID("sheet_")
	station := strings.TrimSpace(m.Station)
	name := strings.TrimSpace(m.Name)
	if station == "" || name == "" || len(station) > 128 || len(name) > 256 || len(m.Unit) > 64 {
		return nil, fmt.Errorf("station and name required")
	}
	rows := make([]storage.Sample, 0, len(preview.Rows))
	now := time.Now().UTC()
	for _, r := range preview.Rows {
		rows = append(rows, storage.Sample{PointID: id, Station: station, Name: name, Value: r.Value, Raw: r.Value, Unit: m.Unit, Quality: "imported", SourceTime: r.Time, ReceivedTime: now, Version: "excel:" + m.SessionID})
	}
	metadata, _ := json.Marshal(map[string]any{"point_id": id, "rows": len(rows), "station": station, "name": name})
	saved, err := s.store.AppendOnce(ctx, key, metadata, rows)
	if err != nil {
		return nil, err
	}
	var result map[string]any
	if err := json.Unmarshal(saved, &result); err != nil {
		return nil, err
	}
	return result, nil
}
func (s *Service) Jobs() []Job { s.mu.Lock(); defer s.mu.Unlock(); return s.jobsLocked() }
func (s *Service) jobsLocked() []Job {
	rows := make([]Job, 0, len(s.jobs))
	for _, j := range s.jobs {
		rows = append(rows, j)
	}
	return rows
}
func (s *Service) update(job Job) error { s.mu.Lock(); defer s.mu.Unlock(); return s.updateLocked(job) }
func (s *Service) updateLocked(job Job) error {
	next := make([]Job, 0, len(s.jobs)+1)
	found := false
	for _, j := range s.jobs {
		if j.ID == job.ID {
			next = append(next, job)
			found = true
		} else {
			next = append(next, j)
		}
	}
	if !found {
		next = append(next, job)
	}
	if err := s.store.SaveConfig("jobs", next); err != nil {
		return err
	}
	s.jobs[job.ID] = job
	return nil
}

func (s *Service) Export(f storage.Filter, format string) (Job, error) {
	if format != "csv" && format != "xlsx" {
		return Job{}, fmt.Errorf("invalid format")
	}
	boundary, err := s.store.Boundary()
	if err != nil {
		return Job{}, err
	}
	if f.Before == 0 || f.Before > boundary {
		f.Before = boundary
	}
	if boundary == 0 {
		f.Before = -1
	}
	f.Offset = 0
	f.Limit = 1000
	s.mu.Lock()
	count := len(s.jobs)
	s.mu.Unlock()
	if count >= 64 {
		return Job{}, fmt.Errorf("export job limit; remove completed jobs")
	}
	job := Job{ID: ID("export_"), State: "queued", Format: format, At: time.Now().UTC()}
	if err := s.update(job); err != nil {
		return Job{}, err
	}
	select {
	case s.queue <- exportTask{job.ID, f, format}:
		return job, nil
	default:
		job.State = "failed"
		job.Message = "export queue full"
		_ = s.update(job)
		return job, fmt.Errorf("export queue full")
	}
}
func (s *Service) File(id string) (string, string, error) {
	s.mu.Lock()
	j, ok := s.jobs[id]
	s.mu.Unlock()
	if !ok || j.State != "completed" {
		return "", "", fmt.Errorf("export not complete")
	}
	return filepath.Join(s.dir, j.ID+"."+j.Format), j.Format, nil
}
func (s *Service) Cancel(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	j, ok := s.jobs[id]
	if !ok {
		return fmt.Errorf("job not found")
	}
	if j.State == "completed" || j.State == "failed" {
		return fmt.Errorf("job already finished")
	}
	j.State = "cancelled"
	return s.updateLocked(j)
}

func (s *Service) Remove(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	j, ok := s.jobs[id]
	if !ok {
		return fmt.Errorf("job not found")
	}
	if j.State == "queued" || j.State == "running" {
		return fmt.Errorf("cancel job first")
	}
	if j.State == "completed" {
		if err := os.Remove(filepath.Join(s.dir, j.ID+"."+j.Format)); err != nil && !os.IsNotExist(err) {
			return err
		}
	}
	delete(s.jobs, id)
	return s.store.SaveConfig("jobs", s.jobsLocked())
}
func safeCSV(s string) string {
	if len(s) > 0 && strings.ContainsAny(s[:1], "=+-@\t\r") {
		return "'" + s
	}
	return s
}
func (s *Service) run(task exportTask) {
	s.mu.Lock()
	job, exists := s.jobs[task.ID]
	s.mu.Unlock()
	if !exists || job.State == "cancelled" {
		return
	}
	job.State = "running"
	if err := s.update(job); err != nil {
		return
	}
	tmp, err := os.CreateTemp(s.dir, ".export-*")
	if err != nil {
		job.State = "failed"
		job.Message = err.Error()
		_ = s.update(job)
		return
	}
	path := tmp.Name()
	defer os.Remove(path)
	var book *excelize.File
	var csvOut *csv.Writer
	headers := []string{"UTC source time", "Station", "Point", "Point ID", "Value", "Unit", "Quality", "Config version"}
	if task.Format == "csv" {
		csvOut = csv.NewWriter(tmp)
		err = csvOut.Write(headers)
	} else {
		book = excelize.NewFile()
		defer book.Close()
		for i, v := range headers {
			cell, _ := excelize.CoordinatesToCellName(i+1, 1)
			_ = book.SetCellStr("Sheet1", cell, v)
		}
		_ = book.SetColWidth("Sheet1", "A", "A", 28)
		_ = book.SetColWidth("Sheet1", "B", "H", 20)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	rowIndex := 2
	for err == nil {
		s.mu.Lock()
		cancelled := s.jobs[job.ID].State == "cancelled"
		s.mu.Unlock()
		if cancelled {
			tmp.Close()
			return
		}
		select {
		case <-s.stop:
			err = fmt.Errorf("shutdown")
		default:
		}
		if err != nil {
			break
		}
		var rows []storage.Sample
		rows, err = s.store.Query(ctx, task.Filter)
		if err != nil || len(rows) == 0 {
			break
		}
		for _, r := range rows {
			if job.Rows >= 50000 {
				err = fmt.Errorf("export limit 50000; narrow filters")
				break
			}
			fields := []string{r.SourceTime.Format(time.RFC3339Nano), r.Station, r.Name, r.PointID, fmt.Sprint(r.Value), r.Unit, r.Quality, r.Version}
			if csvOut != nil {
				for i, v := range fields {
					if i == 4 {
						if _, ok := r.Value.(float64); ok {
							continue
						}
					}
					fields[i] = safeCSV(v)
				}
				if err = csvOut.Write(fields); err != nil {
					break
				}
			} else {
				for i, v := range fields {
					cell, _ := excelize.CoordinatesToCellName(i+1, rowIndex)
					if i == 4 {
						if n, ok := r.Value.(float64); ok {
							err = book.SetCellFloat("Sheet1", cell, n, -1, 64)
						} else {
							err = book.SetCellStr("Sheet1", cell, v)
						}
					} else {
						err = book.SetCellStr("Sheet1", cell, v)
					}
					if err != nil {
						break
					}
				}
			}
			if err != nil {
				break
			}
			job.Rows++
			rowIndex++
		}
		task.Filter.After = rows[len(rows)-1].Seq
	}
	if err == nil {
		if csvOut != nil {
			csvOut.Flush()
			err = csvOut.Error()
		} else {
			err = book.Write(tmp)
		}
	}
	if err == nil {
		err = tmp.Sync()
	}
	closeErr := tmp.Close()
	if err == nil {
		err = closeErr
	}
	// Cancellation, publication and completed-state persistence share one lock.
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.jobs[job.ID].State == "cancelled" {
		return
	}
	if err == nil {
		err = os.Rename(path, filepath.Join(s.dir, job.ID+"."+job.Format))
	}
	if err != nil {
		job.State = "failed"
		job.Message = err.Error()
	} else {
		job.State = "completed"
		job.Message = "query snapshot exported"
	}
	if err := s.updateLocked(job); err != nil {
		// Never advertise completion when durable task-state persistence failed.
		job.State = "failed"
		job.Message = "task state could not be persisted: " + err.Error()
		s.jobs[job.ID] = job
	}
}

func (s *Service) loop() {
	defer close(s.done)
	for {
		select {
		case <-s.stop:
			return
		case task := <-s.queue:
			s.run(task)
		}
	}
}
