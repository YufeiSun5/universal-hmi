package externaldata

import (
	"fmt"
	"slices"
	"strings"
)

var historyFieldKeys = []string{"target_time", "sample_time", "match", "quality"}

// Numeric point columns are independent of these optional metadata columns.
func validateHistoryColumns(columns []DisplayColumn, kind string) error {
	if columns == nil {
		return nil
	}
	if kind != "standard" || len(columns) != len(historyFieldKeys) {
		return fmt.Errorf("历史列配置必须包含全部时间、匹配和质量字段")
	}
	seen := map[string]bool{}
	for i, c := range columns {
		columns[i].Label = strings.TrimSpace(c.Label)
		if !slices.Contains(historyFieldKeys, c.Key) || seen[c.Key] || !validName(columns[i].Label) {
			return fmt.Errorf("历史字段或列头无效")
		}
		seen[c.Key] = true
	}
	return nil
}
