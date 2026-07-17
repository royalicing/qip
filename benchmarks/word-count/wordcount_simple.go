package main

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"regexp"
	"sort"
	"strings"
)

var wordRE = regexp.MustCompile(`[A-Za-z]+`)

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
	for _, raw := range wordRE.FindAll(in, -1) {
		w := strings.ToLower(string(raw))
		counts[w]++
		total++
	}

	out := format(counts, total)
	if _, err := os.Stdout.Write(out); err != nil {
		fmt.Fprintf(os.Stderr, "write stdout: %v\n", err)
		os.Exit(1)
	}
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
