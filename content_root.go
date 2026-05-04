package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path"
	"regexp"
	"strconv"
	"strings"
	"time"

	qinternal "github.com/royalicing/qip/internal"
)

type contentReadFunc func(ctx context.Context, route qinternal.ContentRoute) ([]byte, error)

type githubContentSpec struct {
	Owner  string
	Repo   string
	Subdir string
}

type githubFetcherConfig struct {
	Client          *http.Client
	InfoRefsBaseURL string
	APIBaseURL      string
	RawBaseURL      string
	Token           string
}

type githubContentSnapshot struct {
	Spec              githubContentSpec
	SHA               string
	RouteEntries      []qinternal.ContentRouteEntry
	PathByRouteSource map[string]string
}

var githubNamePattern = regexp.MustCompile(`^[A-Za-z0-9_.-]+$`)

func defaultGitHubFetcherConfig() githubFetcherConfig {
	token := strings.TrimSpace(os.Getenv("GITHUB_TOKEN"))
	return githubFetcherConfig{
		Client:          &http.Client{Timeout: 20 * time.Second},
		InfoRefsBaseURL: "https://github.com",
		APIBaseURL:      "https://api.github.com",
		RawBaseURL:      "https://raw.githubusercontent.com",
		Token:           token,
	}
}

func validateContentRootArg(contentRoot string) error {
	if _, ok, err := parseGitHubContentRoot(contentRoot); ok || err != nil {
		return err
	}
	contentInfo, err := os.Stat(contentRoot)
	if err != nil {
		return fmt.Errorf("Invalid content directory: %v", err)
	}
	if !contentInfo.IsDir() {
		return fmt.Errorf("Invalid content directory: %q is not a directory", contentRoot)
	}
	return nil
}

func loadContentRoutesAndReader(ctx context.Context, contentRoot string, routeOptions qinternal.RouteOptions) (map[string]qinternal.ContentRoute, contentReadFunc, error) {
	return loadContentRoutesAndReaderWithConfig(ctx, contentRoot, routeOptions, nil)
}

func loadContentRoutesAndReaderWithConfig(ctx context.Context, contentRoot string, routeOptions qinternal.RouteOptions, cfgOverride *githubFetcherConfig) (map[string]qinternal.ContentRoute, contentReadFunc, error) {
	if spec, ok, err := parseGitHubContentRoot(contentRoot); err != nil {
		return nil, nil, err
	} else if ok {
		cfg := defaultGitHubFetcherConfig()
		if cfgOverride != nil {
			cfg = *cfgOverride
		}
		snapshot, err := loadGitHubContentSnapshot(ctx, spec, cfg)
		if err != nil {
			return nil, nil, err
		}
		routes, err := qinternal.BuildContentRoutesFromEntries(snapshot.RouteEntries, routeOptions)
		if err != nil {
			return nil, nil, err
		}
		reader := func(ctx context.Context, route qinternal.ContentRoute) ([]byte, error) {
			repoPath, ok := snapshot.PathByRouteSource[route.FilePath]
			if !ok {
				return nil, fmt.Errorf("missing GitHub source mapping for %q", route.FilePath)
			}
			return fetchGitHubRepoContent(ctx, cfg, snapshot.Spec, snapshot.SHA, repoPath)
		}
		return routes, reader, nil
	}

	routes, err := qinternal.BuildContentRoutes(contentRoot, routeOptions)
	if err != nil {
		return nil, nil, err
	}
	reader := func(_ context.Context, route qinternal.ContentRoute) ([]byte, error) {
		return os.ReadFile(route.FilePath)
	}
	return routes, reader, nil
}

func parseGitHubContentRoot(contentRoot string) (githubContentSpec, bool, error) {
	if !strings.HasPrefix(contentRoot, "github:") {
		return githubContentSpec{}, false, nil
	}

	rest := strings.TrimPrefix(contentRoot, "github:")
	rest = strings.TrimPrefix(rest, "//")
	rest = strings.TrimPrefix(rest, "/")
	rest = strings.TrimSpace(rest)
	if rest == "" {
		return githubContentSpec{}, true, fmt.Errorf("Invalid content directory: %q must include owner/repo", contentRoot)
	}

	parts := strings.Split(rest, "/")
	if len(parts) < 2 {
		return githubContentSpec{}, true, fmt.Errorf("Invalid content directory: %q must include owner/repo", contentRoot)
	}

	owner := strings.TrimSpace(parts[0])
	repo := strings.TrimSpace(parts[1])
	if owner == "" || repo == "" {
		return githubContentSpec{}, true, fmt.Errorf("Invalid content directory: %q must include owner/repo", contentRoot)
	}
	if !githubNamePattern.MatchString(owner) {
		return githubContentSpec{}, true, fmt.Errorf("Invalid GitHub owner in content directory: %q", owner)
	}
	if !githubNamePattern.MatchString(repo) {
		return githubContentSpec{}, true, fmt.Errorf("Invalid GitHub repo in content directory: %q", repo)
	}

	subdir := ""
	if len(parts) > 2 {
		subdir = strings.Join(parts[2:], "/")
	}
	subdir = strings.TrimSpace(subdir)
	subdir = strings.Trim(subdir, "/")
	if strings.Contains(subdir, "\\") {
		return githubContentSpec{}, true, fmt.Errorf("Invalid GitHub content subdir %q: backslash is not allowed", subdir)
	}
	if subdir != "" {
		clean := path.Clean(subdir)
		if clean == "." {
			subdir = ""
		} else {
			if clean == ".." || strings.HasPrefix(clean, "../") {
				return githubContentSpec{}, true, fmt.Errorf("Invalid GitHub content subdir %q", subdir)
			}
			subdir = clean
		}
	}

	return githubContentSpec{Owner: owner, Repo: repo, Subdir: subdir}, true, nil
}

func loadGitHubContentSnapshot(ctx context.Context, spec githubContentSpec, cfg githubFetcherConfig) (githubContentSnapshot, error) {
	sha, err := fetchGitHubHeadSHA(ctx, cfg, spec)
	if err != nil {
		return githubContentSnapshot{}, err
	}
	files, err := fetchGitHubRepoFiles(ctx, cfg, spec, sha)
	if err != nil {
		return githubContentSnapshot{}, err
	}
	if len(files) == 0 {
		if spec.Subdir == "" {
			return githubContentSnapshot{}, fmt.Errorf("No content files found in github:%s/%s at HEAD %s", spec.Owner, spec.Repo, sha)
		}
		return githubContentSnapshot{}, fmt.Errorf("No content files found in github:%s/%s/%s at HEAD %s", spec.Owner, spec.Repo, spec.Subdir, sha)
	}

	entries := make([]qinternal.ContentRouteEntry, 0, len(files))
	pathByRouteSource := make(map[string]string, len(files))
	for _, item := range files {
		repoPath := item
		relPath := item
		if spec.Subdir != "" {
			relPath = strings.TrimPrefix(item, spec.Subdir+"/")
			if relPath == item {
				continue
			}
		}
		routeSource := fmt.Sprintf("github:%s/%s@%s/%s", spec.Owner, spec.Repo, sha, repoPath)
		entries = append(entries, qinternal.ContentRouteEntry{RelPath: relPath, FilePath: routeSource})
		pathByRouteSource[routeSource] = repoPath
	}
	if len(entries) == 0 {
		if spec.Subdir == "" {
			return githubContentSnapshot{}, fmt.Errorf("No content files found in github:%s/%s at HEAD %s", spec.Owner, spec.Repo, sha)
		}
		return githubContentSnapshot{}, fmt.Errorf("No content files found under github:%s/%s/%s at HEAD %s", spec.Owner, spec.Repo, spec.Subdir, sha)
	}

	return githubContentSnapshot{
		Spec:              spec,
		SHA:               sha,
		RouteEntries:      entries,
		PathByRouteSource: pathByRouteSource,
	}, nil
}

func fetchGitHubHeadSHA(ctx context.Context, cfg githubFetcherConfig, spec githubContentSpec) (string, error) {
	base := strings.TrimRight(cfg.InfoRefsBaseURL, "/")
	infoRefsURL := fmt.Sprintf("%s/%s/%s.git/info/refs?service=git-upload-pack", base, url.PathEscape(spec.Owner), url.PathEscape(spec.Repo))
	resp, err := doGitHubGET(ctx, cfg, infoRefsURL, "")
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return "", fmt.Errorf("fetch github refs failed: %s (%s)", resp.Status, strings.TrimSpace(string(body)))
	}

	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("read github refs: %w", err)
	}

	sha, headRef, ok := parseHeadFromPktLines(data)
	if !ok {
		return "", fmt.Errorf("No HEAD ref found for github:%s/%s", spec.Owner, spec.Repo)
	}
	if len(sha) != 40 {
		return "", fmt.Errorf("invalid HEAD sha %q for github:%s/%s (%s)", sha, spec.Owner, spec.Repo, headRef)
	}
	return sha, nil
}

func parseHeadFromPktLines(data []byte) (string, string, bool) {
	current := 0
	for {
		if current+4 > len(data) {
			break
		}
		lengthHex := string(data[current : current+4])
		current += 4
		length, err := strconv.ParseInt(lengthHex, 16, 32)
		if err != nil {
			return "", "", false
		}
		if length == 0 {
			continue
		}
		if length < 4 {
			continue
		}
		payloadLen := int(length) - 4
		if current+payloadLen > len(data) {
			return "", "", false
		}
		payload := bytes.TrimRight(data[current:current+payloadLen], "\n")
		current += payloadLen
		line := string(payload)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		parts := strings.Split(line, " ")
		if len(parts) < 2 {
			continue
		}
		sha := strings.TrimSpace(parts[0])
		refRaw := parts[1]
		attrs := parts[2:]

		if cut := strings.IndexByte(refRaw, 0); cut >= 0 {
			capTail := strings.TrimSpace(refRaw[cut+1:])
			refRaw = refRaw[:cut]
			if capTail != "" {
				attrs = append([]string{capTail}, attrs...)
			}
		}
		for _, attr := range attrs {
			if strings.HasPrefix(attr, "symref=HEAD:") {
				headRef := strings.TrimPrefix(attr, "symref=HEAD:")
				return sha, headRef, true
			}
			if strings.HasPrefix(attr, "symref-target:") {
				headRef := strings.TrimPrefix(attr, "symref-target:")
				return sha, headRef, true
			}
		}
	}
	return "", "", false
}

func fetchGitHubRepoFiles(ctx context.Context, cfg githubFetcherConfig, spec githubContentSpec, sha string) ([]string, error) {
	base := strings.TrimRight(cfg.APIBaseURL, "/")
	treeURL := fmt.Sprintf("%s/repos/%s/%s/git/trees/%s?recursive=1", base, url.PathEscape(spec.Owner), url.PathEscape(spec.Repo), url.PathEscape(sha))
	resp, err := doGitHubGET(ctx, cfg, treeURL, "application/vnd.github+json")
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return nil, fmt.Errorf("fetch github tree failed: %s (%s)", resp.Status, strings.TrimSpace(string(body)))
	}

	var payload struct {
		Tree []struct {
			Path string `json:"path"`
			Type string `json:"type"`
		} `json:"tree"`
		Truncated bool `json:"truncated"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return nil, fmt.Errorf("decode github tree response: %w", err)
	}
	if payload.Truncated {
		return nil, fmt.Errorf("github tree response is truncated for github:%s/%s; repository is too large for recursive tree listing", spec.Owner, spec.Repo)
	}

	files := make([]string, 0, len(payload.Tree))
	for _, item := range payload.Tree {
		if item.Type != "blob" {
			continue
		}
		p := strings.Trim(strings.TrimSpace(item.Path), "/")
		if p == "" {
			continue
		}
		if spec.Subdir != "" {
			if p == spec.Subdir || strings.HasPrefix(p, spec.Subdir+"/") {
				files = append(files, p)
			}
			continue
		}
		files = append(files, p)
	}
	return files, nil
}

func fetchGitHubRepoContent(ctx context.Context, cfg githubFetcherConfig, spec githubContentSpec, sha string, repoPath string) ([]byte, error) {
	base := strings.TrimRight(cfg.RawBaseURL, "/")
	cleanRepoPath := path.Clean(strings.TrimPrefix(repoPath, "/"))
	if cleanRepoPath == "." || cleanRepoPath == ".." || strings.HasPrefix(cleanRepoPath, "../") {
		return nil, fmt.Errorf("invalid github repo path %q", repoPath)
	}
	escapedPathSegments := strings.Split(cleanRepoPath, "/")
	for i := range escapedPathSegments {
		escapedPathSegments[i] = url.PathEscape(escapedPathSegments[i])
	}
	rawURL := fmt.Sprintf("%s/%s/%s/%s/%s", base, url.PathEscape(spec.Owner), url.PathEscape(spec.Repo), url.PathEscape(sha), strings.Join(escapedPathSegments, "/"))
	resp, err := doGitHubGET(ctx, cfg, rawURL, "")
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return nil, fmt.Errorf("fetch github repo content failed: %s %s (%s)", resp.Status, sha, strings.TrimSpace(string(body)))
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read github repo content: %w", err)
	}
	return body, nil
}

func doGitHubGET(ctx context.Context, cfg githubFetcherConfig, rawURL string, accept string) (*http.Response, error) {
	client := cfg.Client
	if client == nil {
		client = defaultGitHubFetcherConfig().Client
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "qip")
	if accept != "" {
		req.Header.Set("Accept", accept)
	}
	if cfg.Token != "" {
		req.Header.Set("Authorization", "Bearer "+cfg.Token)
	}
	return client.Do(req)
}
