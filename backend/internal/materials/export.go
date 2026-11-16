package materials

import (
	"golang.org/x/text/width"
	"unicode"
)

type exportTextPart struct {
	Text  string
	Lines int
}

// Excel width units are narrow characters. CJK occupies two units, combining
// marks none. Physical continuation rows preserve the complete original text.
func exportTextParts(value string, capacity, maxLines int) []exportTextPart {
	capacity = max(2, capacity)
	maxLines = max(2, maxLines)
	runes := []rune(value)
	start, used, lines := 0, 0, 1
	parts := []exportTextPart{}
	units := func(r rune) int {
		if unicode.Is(unicode.Mn, r) || unicode.Is(unicode.Me, r) {
			return 0
		}
		if r == '\t' {
			return 4
		}
		switch width.LookupRune(r).Kind() {
		case width.EastAsianWide, width.EastAsianFullwidth:
			return 2
		}
		if r == 'W' || r == 'M' {
			return 2
		}
		return 1
	}
	wide := func(r rune) bool {
		k := width.LookupRune(r).Kind()
		return k == width.EastAsianWide || k == width.EastAsianFullwidth
	}
	nextLine := func(at int) {
		if lines == maxLines {
			parts = append(parts, exportTextPart{string(runes[start:at]), lines})
			start, lines = at, 1
		} else {
			lines++
		}
		used = 0
	}
	for i := 0; i < len(runes); {
		r := runes[i]
		if r == '\r' || r == '\n' {
			end := i + 1
			if r == '\r' && end < len(runes) && runes[end] == '\n' {
				end++
			}
			nextLine(end)
			i = end
			continue
		}
		end, n := i+1, units(r)
		// Excel wraps Latin words at whitespace rather than at arbitrary character
		// counts. Treat a whole narrow word as a unit, and long words conservatively.
		if !unicode.IsSpace(r) && !wide(r) {
			for end < len(runes) && !unicode.IsSpace(runes[end]) && !wide(runes[end]) {
				n += units(runes[end])
				end++
			}
		}
		if n <= capacity {
			if used+n > capacity {
				nextLine(i)
			}
			used += n
		} else {
			if used > 0 {
				nextLine(i)
			}
			for at := i; at < end; at++ {
				count := units(runes[at])
				if used+count > capacity {
					nextLine(at)
				}
				used += count
			}
		}
		i = end
	}
	if start < len(runes) || len(parts) == 0 {
		parts = append(parts, exportTextPart{string(runes[start:]), lines})
	}
	return parts
}
