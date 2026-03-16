//go:build ignore

package main

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"sort"
)

type entry struct {
	Word  string
	Count int
}

func main() {
	in, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintf(os.Stderr, "read stdin: %v\n", err)
		os.Exit(1)
	}

	counts := map[string]int{}
	total := 0
	buf := make([]byte, 0, 64)

	flush := func() {
		if len(buf) == 0 {
			return
		}
		w := string(buf)
		counts[w]++
		total++
		buf = buf[:0]
	}

	for _, c := range in {
		if isLetter(c) {
			buf = append(buf, lowerASCII(c))
			continue
		}
		flush()
	}
	flush()

	out := format(counts, total)
	if _, err := os.Stdout.Write(out); err != nil {
		fmt.Fprintf(os.Stderr, "write stdout: %v\n", err)
		os.Exit(1)
	}
}

func isLetter(c byte) bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

func lowerASCII(c byte) byte {
	if c >= 'A' && c <= 'Z' {
		return c + 32
	}
	return c
}

func format(counts map[string]int, total int) []byte {
	entries := make([]entry, 0, len(counts))
	for w, c := range counts {
		entries = append(entries, entry{Word: w, Count: c})
	}
	sort.Slice(entries, func(i, j int) bool {
		if entries[i].Count != entries[j].Count {
			return entries[i].Count > entries[j].Count
		}
		return entries[i].Word < entries[j].Word
	})

	var b bytes.Buffer
	n := len(entries)
	if n > 10 {
		n = 10
	}
	for i := 0; i < n; i++ {
		fmt.Fprintf(&b, "%d\t%s\n", entries[i].Count, entries[i].Word)
	}
	fmt.Fprint(&b, "--\n")
	fmt.Fprintf(&b, "total\t%d\n", total)
	fmt.Fprintf(&b, "unique\t%d\n", len(entries))
	return b.Bytes()
}
