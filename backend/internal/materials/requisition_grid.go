package materials

import (
	"math"
	"sort"
)

type requisitionSpan struct{ first, last int }
type requisitionGrid struct {
	widths             []float64
	table              [7]requisitionSpan
	labels, signatures [4]requisitionSpan
	signatureWidth     float64
}

// A shared fine grid keeps the seven original table widths while providing
// four equal footer groups, each with a separate label and signature region.
func newRequisitionGrid(widths []float64) requisitionGrid {
	g := requisitionGrid{}
	tableEdges := []float64{0}
	for _, w := range widths {
		tableEdges = append(tableEdges, tableEdges[len(tableEdges)-1]+w)
	}
	total := tableEdges[len(tableEdges)-1]
	group := total / 4
	label := math.Min(6, group*.35)
	g.signatureWidth = group - label
	edges := append([]float64{}, tableEdges...)
	for i := 0; i < 4; i++ {
		edges = append(edges, float64(i)*group, float64(i)*group+label, float64(i+1)*group)
	}
	sort.Float64s(edges)
	unique := []float64{}
	for _, v := range edges {
		if len(unique) == 0 || math.Abs(v-unique[len(unique)-1]) > .0001 {
			unique = append(unique, v)
		}
	}
	for i := 1; i < len(unique); i++ {
		g.widths = append(g.widths, unique[i]-unique[i-1])
	}
	index := func(v float64) int {
		for i, edge := range unique {
			if math.Abs(v-edge) < .0001 {
				return i
			}
		}
		panic("missing requisition grid edge")
	}
	span := func(a, b float64) requisitionSpan { return requisitionSpan{index(a) + 1, index(b)} }
	for i := range g.table {
		g.table[i] = span(tableEdges[i], tableEdges[i+1])
	}
	for i := range g.labels {
		a := float64(i) * group
		g.labels[i] = span(a, a+label)
		g.signatures[i] = span(a+label, a+group)
	}
	return g
}
