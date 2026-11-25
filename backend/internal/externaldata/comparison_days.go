package externaldata

import (
	"math/big"
	"sort"
	"strings"
)

// Daily chart projection only. Each field uses the fragments with its own
// readings. Database summary and paired comparisons are separate.
func comparisonDays(rows []map[string]*string) []map[string]*string {
	groups := map[string][]map[string]*string{}
	for _, r := range rows {
		key := value(r["整站编码"]) + "/" + value(r["指标"]) + "/" + strings.Split(value(r["本期开始"]), "T")[0]
		groups[key] = append(groups[key], r)
	}
	keys := []string{}
	for k := range groups {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	out := []map[string]*string{}
	ptr := func(s string) *string { return &s }
	for _, k := range keys {
		group := groups[k]
		sort.Slice(group, func(i, j int) bool { return value(group[i]["本期开始"]) < value(group[j]["本期开始"]) })
		first, last := group[0], group[len(group)-1]
		r := map[string]*string{
			"整站编码": first["整站编码"], "指标": first["指标"], "单位": first["单位"],
			"本期开始": first["本期开始"], "本期结束": last["本期结束"],
			"历史开始": first["历史开始"], "历史结束": last["历史结束"],
		}
		for _, field := range []string{"本期用量", "历史折算用量", "本期平均气温", "历史整点气温"} {
			sum, weight := new(big.Rat), new(big.Rat)
			hasReading := false
			temp := strings.Contains(field, "气温")
			for _, part := range group {
				n, ok := new(big.Rat).SetString(value(part[field]))
				if !ok {
					continue
				}
				if temp {
					seconds, ok := new(big.Rat).SetString(value(part["片段秒数"]))
					if !ok || seconds.Sign() <= 0 {
						continue
					}
					n.Mul(n, seconds)
					weight.Add(weight, seconds)
				}
				sum.Add(sum, n)
				hasReading = true
			}
			r[field] = nil
			if hasReading {
				if temp {
					sum.Quo(sum, weight)
				}
				r[field] = ptr(sum.FloatString(8))
			}
		}
		out = append(out, r)
	}
	return out
}
