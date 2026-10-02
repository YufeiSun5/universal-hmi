package points

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

const MaxDefinitions = 20000

var ErrInvalid = errors.New("invalid point")

type Definition struct {
	ID            string   `json:"id"`
	Station       string   `json:"station"`
	Name          string   `json:"name"`
	DataType      string   `json:"data_type"`
	SourceType    string   `json:"source_type"`
	SourceID      string   `json:"source_id"`
	SourcePath    string   `json:"source_path"`
	Unit          string   `json:"unit"`
	ScaleFactor   float64  `json:"scale_factor"`
	Offset        float64  `json:"offset"`
	Topic         string   `json:"topic"`
	Writable      bool     `json:"writable"`
	WriteTopic    string   `json:"write_topic"`
	RWMode        string   `json:"rw_mode"`
	WriteSourceID string   `json:"write_source_id"`
	WritePath     string   `json:"write_path"`
	Min           *float64 `json:"min"`
	Max           *float64 `json:"max"`
	Expression    string   `json:"expression"`
	Inputs        []string `json:"inputs"`
	StaleMS       int      `json:"stale_ms"`
}

type CreateInput struct {
	Station       string   `json:"station"`
	Name          string   `json:"name"`
	DataType      string   `json:"data_type"`
	SourceType    string   `json:"source_type"`
	SourceID      string   `json:"source_id"`
	SourcePath    string   `json:"source_path"`
	Unit          string   `json:"unit"`
	ScaleFactor   *float64 `json:"scale_factor"`
	Offset        float64  `json:"offset"`
	Topic         string   `json:"topic"`
	Writable      bool     `json:"writable"`
	WriteTopic    string   `json:"write_topic"`
	RWMode        string   `json:"rw_mode"`
	WriteSourceID string   `json:"write_source_id"`
	WritePath     string   `json:"write_path"`
	Min           *float64 `json:"min"`
	Max           *float64 `json:"max"`
	Expression    string   `json:"expression"`
	Inputs        []string `json:"inputs"`
	StaleMS       int      `json:"stale_ms"`
}

// Service owns configuration only. No saved definition implies a live source.
type Service struct {
	mu   sync.Mutex
	path string
	rows []Definition
}

func Open(path string) (*Service, error) {
	s := &Service{path: path, rows: make([]Definition, 0)}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return s, nil
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(data, &s.rows); err != nil {
		return nil, fmt.Errorf("read point configuration: %w", err)
	}
	if s.rows == nil {
		s.rows = make([]Definition, 0)
	}
	return s, nil
}

func (s *Service) List() []Definition {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append(make([]Definition, 0, len(s.rows)), s.rows...)
}

func normalize(in CreateInput) (Definition, error) {
	p := Definition{
		Station: strings.TrimSpace(in.Station), Name: strings.TrimSpace(in.Name),
		DataType:   strings.ToUpper(strings.TrimSpace(in.DataType)),
		SourceType: strings.ToLower(strings.TrimSpace(in.SourceType)),
		SourceID:   strings.TrimSpace(in.SourceID), SourcePath: strings.TrimSpace(in.SourcePath),
		Unit: strings.TrimSpace(in.Unit), ScaleFactor: 1, Offset: in.Offset,
		Topic: strings.TrimSpace(in.Topic), Writable: in.Writable, WriteTopic: strings.TrimSpace(in.WriteTopic),
		RWMode: strings.ToUpper(strings.TrimSpace(in.RWMode)), WriteSourceID: strings.TrimSpace(in.WriteSourceID), WritePath: strings.TrimSpace(in.WritePath),
		Min: in.Min, Max: in.Max, Expression: in.Expression, Inputs: append([]string(nil), in.Inputs...), StaleMS: in.StaleMS,
	}
	if p.RWMode == "" {
		p.RWMode = "R"
		if p.Writable && (p.SourceType == "manual" || p.SourceType == "simulator") {
			p.RWMode = "RW"
		}
	}
	if p.RWMode != "R" && p.RWMode != "W" && p.RWMode != "RW" {
		return p, fmt.Errorf("%w: rw_mode must be R, W, or RW", ErrInvalid)
	}
	if len(p.WriteSourceID) > 64 || len(p.WritePath) > 1024 {
		return p, fmt.Errorf("%w: write target limits", ErrInvalid)
	}
	if in.ScaleFactor != nil {
		p.ScaleFactor = *in.ScaleFactor
	}
	if p.Station == "" || p.Name == "" || len(p.Station) > 128 || len(p.Name) > 256 {
		return p, fmt.Errorf("%w: station and name are required and must fit their limits", ErrInvalid)
	}
	switch p.DataType {
	case "FLOAT", "INT", "BOOL", "STRING":
	default:
		return p, fmt.Errorf("%w: unsupported data_type", ErrInvalid)
	}
	switch p.SourceType {
	case "manual", "virtual", "simulator":
	case "mqtt":
		if p.SourceID == "" || p.SourcePath == "" {
			return p, fmt.Errorf("%w: mqtt requires source_id and source_path", ErrInvalid)
		}
	default:
		return p, fmt.Errorf("%w: unsupported source_type", ErrInvalid)
	}
	if math.IsNaN(p.ScaleFactor) || math.IsInf(p.ScaleFactor, 0) || p.ScaleFactor == 0 ||
		math.IsNaN(p.Offset) || math.IsInf(p.Offset, 0) {
		return p, fmt.Errorf("%w: conversion must be finite and scale_factor nonzero", ErrInvalid)
	}
	if len(p.SourceID) > 64 || len(p.SourcePath) > 1024 || len(p.Topic) > 512 || len(p.WriteTopic) > 512 || len(p.Unit) > 64 || strings.ContainsAny(p.WriteTopic, "+#") {
		return p, fmt.Errorf("%w: invalid source or unit limits", ErrInvalid)
	}
	if (p.DataType == "BOOL" || p.DataType == "STRING") && (p.ScaleFactor != 1 || p.Offset != 0) {
		return p, fmt.Errorf("%w: boolean and string conversions must be identity", ErrInvalid)
	}
	if p.StaleMS == 0 {
		p.StaleMS = 5000
	}
	if p.StaleMS < 200 || p.StaleMS > 86400000 || len(p.Expression) > 2048 || len(p.Inputs) > 64 {
		return p, fmt.Errorf("%w: invalid runtime limits", ErrInvalid)
	}
	if (p.Min != nil && (math.IsNaN(*p.Min) || math.IsInf(*p.Min, 0))) || (p.Max != nil && (math.IsNaN(*p.Max) || math.IsInf(*p.Max, 0))) || (p.Min != nil && p.Max != nil && *p.Min > *p.Max) {
		return p, fmt.Errorf("%w: invalid write range", ErrInvalid)
	}
	if p.SourceType == "virtual" && p.Writable {
		return p, fmt.Errorf("%w: calculated points are read only", ErrInvalid)
	}
	return p, nil
}

func (s *Service) Create(in CreateInput) (Definition, error) {
	p, err := normalize(in)
	if err != nil {
		return p, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.rows) >= MaxDefinitions {
		return p, fmt.Errorf("%w: point limit", ErrInvalid)
	}
	for _, row := range s.rows {
		if row.Station == p.Station && row.Name == p.Name {
			return p, fmt.Errorf("%w: point name already exists in station", ErrInvalid)
		}
		if p.SourceType == "mqtt" && row.SourceType == "mqtt" &&
			row.SourceID == p.SourceID && row.Topic == p.Topic && row.SourcePath == p.SourcePath {
			return p, fmt.Errorf("%w: source identity already exists", ErrInvalid)
		}
	}
	var id [12]byte
	if _, err := rand.Read(id[:]); err != nil {
		return p, err
	}
	p.ID = "pt_" + hex.EncodeToString(id[:])
	next := append(append([]Definition(nil), s.rows...), p)
	if err := s.save(next); err != nil {
		return Definition{}, err
	}
	s.rows = next
	return p, nil
}

func (s *Service) save(rows []Definition) error {
	if err := os.MkdirAll(filepath.Dir(s.path), 0700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(rows, "", "  ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(s.path), ".points-*.tmp")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err = tmp.Write(data); err != nil {
		_ = tmp.Close()
		return err
	}
	if err = tmp.Sync(); err != nil {
		_ = tmp.Close()
		return err
	}
	if err = tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), s.path)
}

func (s *Service) Update(id string, in CreateInput) (Definition, error) {
	p, err := normalize(in)
	if err != nil {
		return p, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	index := -1
	for i, row := range s.rows {
		if row.ID == id {
			index = i
			continue
		}
		if (row.Station == p.Station && row.Name == p.Name) || (p.SourceType == "mqtt" && row.SourceType == "mqtt" && row.SourceID == p.SourceID && row.Topic == p.Topic && row.SourcePath == p.SourcePath) {
			return p, fmt.Errorf("%w: duplicate identity", ErrInvalid)
		}
	}
	if index < 0 {
		return p, fmt.Errorf("%w: point not found", ErrInvalid)
	}
	p.ID = id
	next := append([]Definition(nil), s.rows...)
	next[index] = p
	if err := s.save(next); err != nil {
		return Definition{}, err
	}
	s.rows = next
	return p, nil
}
func (s *Service) Delete(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	next := make([]Definition, 0, len(s.rows))
	found := false
	for _, p := range s.rows {
		if p.ID == id {
			found = true
		} else {
			next = append(next, p)
		}
	}
	if !found {
		return fmt.Errorf("%w: point not found", ErrInvalid)
	}
	if err := s.save(next); err != nil {
		return err
	}
	s.rows = next
	return nil
}

// CreateBatch validates all identities before one atomic configuration write.
func (s *Service) CreateBatch(inputs []CreateInput) ([]Definition, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(inputs) == 0 || len(inputs)+len(s.rows) > MaxDefinitions {
		return nil, fmt.Errorf("%w: point limit %d", ErrInvalid, MaxDefinitions)
	}
	names, identities := map[string]bool{}, map[string]bool{}
	for _, p := range s.rows {
		names[p.Station+"\x00"+p.Name] = true
		if p.SourceType == "mqtt" {
			identities[p.SourceID+"\x00"+p.Topic+"\x00"+p.SourcePath] = true
		}
	}
	created := make([]Definition, 0, len(inputs))
	for _, in := range inputs {
		p, err := normalize(in)
		if err != nil {
			return nil, err
		}
		name := p.Station + "\x00" + p.Name
		identity := p.SourceID + "\x00" + p.Topic + "\x00" + p.SourcePath
		if names[name] || p.SourceType == "mqtt" && identities[identity] {
			return nil, fmt.Errorf("%w: duplicate identity", ErrInvalid)
		}
		names[name] = true
		if p.SourceType == "mqtt" {
			identities[identity] = true
		}
		var id [12]byte
		if _, err := rand.Read(id[:]); err != nil {
			return nil, err
		}
		p.ID = "pt_" + hex.EncodeToString(id[:])
		created = append(created, p)
	}
	next := append(append([]Definition(nil), s.rows...), created...)
	if err := s.save(next); err != nil {
		return nil, err
	}
	s.rows = next
	return created, nil
}
