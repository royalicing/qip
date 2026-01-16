qip: main.go go.mod go.sum
	go build -ldflags="-s -w" -trimpath
