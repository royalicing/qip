package main

import (
	"bytes"
	"compress/flate"
	"compress/zlib"
	"flag"
	"fmt"
	"io"
	"os"
)

func compressOnce(in []byte, level int) ([]byte, error) {
	var out bytes.Buffer
	zw, err := zlib.NewWriterLevel(&out, level)
	if err != nil {
		return nil, err
	}
	if _, err := zw.Write(in); err != nil {
		_ = zw.Close()
		return nil, err
	}
	if err := zw.Close(); err != nil {
		return nil, err
	}
	return out.Bytes(), nil
}

func main() {
	level := flag.Int("level", flate.DefaultCompression, "zlib compression level (-2..9)")
	iters := flag.Int("iters", 1, "number of in-process compression iterations")
	filePath := flag.String("file", "", "input file path (default: stdin)")
	flag.Parse()

	if *iters < 1 {
		fmt.Fprintln(os.Stderr, "iters must be >= 1")
		os.Exit(1)
	}

	var (
		in  []byte
		err error
	)
	if *filePath != "" {
		in, err = os.ReadFile(*filePath)
		if err != nil {
			fmt.Fprintf(os.Stderr, "read file: %v\n", err)
			os.Exit(1)
		}
	} else {
		in, err = io.ReadAll(os.Stdin)
		if err != nil {
			fmt.Fprintf(os.Stderr, "read stdin: %v\n", err)
			os.Exit(1)
		}
	}

	var out []byte
	for i := 0; i < *iters; i++ {
		out, err = compressOnce(in, *level)
		if err != nil {
			fmt.Fprintf(os.Stderr, "compress: %v\n", err)
			os.Exit(1)
		}
	}

	if _, err := os.Stdout.Write(out); err != nil {
		fmt.Fprintf(os.Stderr, "write stdout: %v\n", err)
		os.Exit(1)
	}
}
