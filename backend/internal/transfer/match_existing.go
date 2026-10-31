package transfer

import (
	"context"
	"sort"
	"strings"

	"github.com/YufeiSun5/universal-hmi/backend/internal/points"
)

// MatchCandidate is configuration metadata only. Matching never saves or activates it.
type MatchCandidate struct {
	Definition  points.Definition `json:"definition"`
	Revision    string            `json:"revision"`
	Compatible  bool              `json:"compatible"`
	Conflicts   []string          `json:"conflicts"`
	Differences []string          `json:"differences"`
}

func (s *Service) matchExisting(ctx context.Context, v Variable, sourceMap map[string]string, rows []points.Definition, sourceIDs map[string]bool, offsetProvided bool) (Item, string) {
	it := Item{Kind: "variable", Key: v.Key, Status: "unresolved"}
	in := v.Definition
	source, mapped := sourceMap[in.SourceID]
	if in.SourceType != "mqtt" || strings.TrimSpace(in.SourcePath) == "" || in.DataType == "" {
		it.Message = "match_existing requires confirmed mqtt source path and data type"
		return it, ""
	}
	if !mapped || source == "" {
		it.Message = "source mapping required"
		return it, ""
	}
	if s.Sources == nil || !sourceIDs[source] {
		it.Message = "source target not found"
		return it, ""
	}
	blocked := false
	for _, q := range rows {
		if q.SourceType != "mqtt" || q.SourceID != source || q.SourcePath != in.SourcePath || in.Topic != "" && q.Topic != in.Topic {
			continue
		}
		if !stationAllowed(ctx, q.Station) {
			blocked = true
			continue
		}
		c := MatchCandidate{Definition: q, Revision: points.Revision(q), Conflicts: []string{}, Differences: []string{}}
		if q.DataType != in.DataType {
			c.Conflicts = append(c.Conflicts, "data_type")
		}
		if q.Unit != in.Unit {
			if in.Unit != "" {
				c.Conflicts = append(c.Conflicts, "unit")
			} else {
				c.Differences = append(c.Differences, "unit")
			}
		}
		if in.ScaleFactor != nil && q.ScaleFactor != *in.ScaleFactor {
			c.Conflicts = append(c.Conflicts, "scale_factor")
		}
		if offsetProvided && q.Offset != in.Offset {
			c.Conflicts = append(c.Conflicts, "offset")
		}
		if in.ScaleFactor == nil {
			c.Differences = append(c.Differences, "scale_factor_unspecified")
		}
		if !offsetProvided {
			c.Differences = append(c.Differences, "offset_unspecified")
		}
		if q.Station != in.Station {
			c.Differences = append(c.Differences, "station")
		}
		if q.Topic != in.Topic {
			c.Differences = append(c.Differences, "topic")
		}
		c.Compatible = len(c.Conflicts) == 0
		it.Candidates = append(it.Candidates, c)
	}
	sort.Slice(it.Candidates, func(i, j int) bool { return it.Candidates[i].Definition.ID < it.Candidates[j].Definition.ID })
	if blocked {
		it.Message = "cannot resolve accessible unique match"
		return it, ""
	}
	if len(it.Candidates) != 1 {
		it.Message = "match_existing requires one exact source path candidate"
		return it, ""
	}
	c := it.Candidates[0]
	if !c.Compatible {
		it.Message = "existing variable metadata conflicts with explicit definition"
		return it, ""
	}
	it.Status = "unchanged"
	it.Message = "unique existing source path reference; configuration preserved"
	it.After = c.Definition
	return it, c.Definition.ID
}
