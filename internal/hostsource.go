package qinternal

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	HostDownloadByteLimit = 16 * 1024 * 1024
	hostDownloadTimeout   = 30 * time.Second
	hostRedirectLimit     = 2
)

var hostPattern = regexp.MustCompile(`^([A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+)(?::([0-9]{1,5}))?$`)

type ComponentHost struct {
	Authority string
	Origin    string
}

type ComponentSource struct {
	Kind string
	Path string
	URL  string
}

type ComponentSourcePlan struct {
	FilePath string
	Sources  []ComponentSource
}

func ParseComponentHost(value string) (ComponentHost, error) {
	if value == "" || len(value) > 259 {
		return ComponentHost{}, fmt.Errorf("invalid host %q", value)
	}
	match := hostPattern.FindStringSubmatch(value)
	if match == nil || len(match[1]) > 253 {
		return ComponentHost{}, fmt.Errorf("invalid host %q; use a dotted DNS name with an optional port", value)
	}
	labels := strings.Split(match[1], ".")
	if !strings.ContainsAny(labels[len(labels)-1], "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz") {
		return ComponentHost{}, fmt.Errorf("invalid host %q; IP addresses are not supported", value)
	}
	authority := strings.ToLower(match[1])
	if match[2] != "" {
		port, err := strconv.Atoi(match[2])
		if err != nil || port < 1 || port > 65535 {
			return ComponentHost{}, fmt.Errorf("invalid host port in %q", value)
		}
		authority += ":" + strconv.Itoa(port)
	}
	return ComponentHost{Authority: authority, Origin: "https://" + authority}, nil
}

func RemotelyEligibleComponentPath(filePath string) bool {
	if !strings.HasSuffix(filePath, ".wasm") || filepath.IsAbs(filePath) || strings.Contains(filePath, `\`) {
		return false
	}
	if len(filePath) >= 2 && ((filePath[0] >= 'A' && filePath[0] <= 'Z') || (filePath[0] >= 'a' && filePath[0] <= 'z')) && filePath[1] == ':' {
		return false
	}
	if strings.ContainsAny(filePath, "?#") {
		return false
	}
	for _, r := range filePath {
		if r <= 0x1f || r == 0x7f {
			return false
		}
	}
	segments := strings.Split(filePath, "/")
	for _, segment := range segments {
		if segment == "" || segment == "." || segment == ".." {
			return false
		}
	}
	return len(segments) > 0
}

func PlanComponentSources(filePath string, hosts []ComponentHost) ComponentSourcePlan {
	plan := ComponentSourcePlan{FilePath: filePath, Sources: []ComponentSource{{Kind: "local", Path: filePath}}}
	if !RemotelyEligibleComponentPath(filePath) {
		return plan
	}
	segments := strings.Split(filePath, "/")
	for i := range segments {
		segments[i] = encodeURIComponent(segments[i])
	}
	requestPath := strings.Join(segments, "/")
	for _, host := range hosts {
		plan.Sources = append(plan.Sources, ComponentSource{Kind: "https", URL: host.Origin + "/" + requestPath})
	}
	return plan
}

func encodeURIComponent(value string) string {
	const hexDigits = "0123456789ABCDEF"
	var encoded strings.Builder
	for _, b := range []byte(value) {
		if (b >= 'A' && b <= 'Z') || (b >= 'a' && b <= 'z') || (b >= '0' && b <= '9') || strings.ContainsRune("-_.!~*'()", rune(b)) {
			encoded.WriteByte(b)
			continue
		}
		encoded.WriteByte('%')
		encoded.WriteByte(hexDigits[b>>4])
		encoded.WriteByte(hexDigits[b&0x0f])
	}
	return encoded.String()
}

func ObserveLocalComponentSource(plan ComponentSourcePlan) (state string, body []byte, err error) {
	body, err = os.ReadFile(plan.FilePath)
	if err == nil {
		return "selected", body, nil
	}
	if errors.Is(err, os.ErrNotExist) {
		return "missing", nil, nil
	}
	return "", nil, err
}

type sourceUnavailableError struct{ reason string }

func (e *sourceUnavailableError) Error() string { return e.reason }

func ResolveComponentSource(ctx context.Context, filePath string, hosts []ComponentHost, validate func([]byte, string) error) ([]byte, error) {
	plan := PlanComponentSources(filePath, hosts)
	state, body, err := ObserveLocalComponentSource(plan)
	if err != nil {
		return nil, err
	}
	if state == "selected" {
		if err := validate(body, filePath); err != nil {
			return nil, err
		}
		return body, nil
	}

	unavailable := make([]string, 0, len(hosts))
	for _, source := range plan.Sources[1:] {
		body, finalURL, err := fetchComponentSource(ctx, source.URL)
		var unavailableErr *sourceUnavailableError
		if errors.As(err, &unavailableErr) {
			unavailable = append(unavailable, source.URL+": "+unavailableErr.reason)
			continue
		}
		if err != nil {
			return nil, err
		}
		if err := validate(body, finalURL); err != nil {
			return nil, err
		}
		installed, err := vendorComponentDownload(filePath, body)
		if err != nil {
			return nil, err
		}
		if err := validate(installed, filePath); err != nil {
			return nil, err
		}
		return installed, nil
	}
	if len(plan.Sources) == 1 && !RemotelyEligibleComponentPath(filePath) {
		return nil, fmt.Errorf("%s is missing; only missing relative paths ending in .wasm can be downloaded", filePath)
	}
	detail := ""
	if len(unavailable) > 0 {
		detail = " (" + strings.Join(unavailable, "; ") + ")"
	}
	return nil, fmt.Errorf("%s is unavailable from every source%s", filePath, detail)
}

func fetchComponentSource(parent context.Context, sourceURL string) ([]byte, string, error) {
	ctx, cancel := context.WithTimeout(parent, hostDownloadTimeout)
	defer cancel()
	client := &http.Client{CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }}
	current := sourceURL
	source, _ := url.Parse(sourceURL)
	for redirects := 0; redirects <= hostRedirectLimit; redirects++ {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, current, nil)
		if err != nil {
			return nil, "", err
		}
		resp, err := client.Do(req)
		if err != nil {
			return nil, "", &sourceUnavailableError{reason: err.Error()}
		}
		if resp.StatusCode >= 300 && resp.StatusCode <= 399 {
			resp.Body.Close()
			if redirects == hostRedirectLimit {
				return nil, "", fmt.Errorf("%s exceeded the %d-redirect limit", sourceURL, hostRedirectLimit)
			}
			location := resp.Header.Get("Location")
			if location == "" {
				return nil, "", fmt.Errorf("%s returned HTTP %d without Location", current, resp.StatusCode)
			}
			base, _ := url.Parse(current)
			next, err := base.Parse(location)
			if err != nil || !sameHTTPSOrigin(source, next) || (next.User != nil && (next.User.Username() != "" || hasURLPassword(next.User))) {
				return nil, "", fmt.Errorf("%s redirected outside its HTTPS origin", current)
			}
			current = next.String()
			continue
		}
		if resp.StatusCode == http.StatusNotFound || resp.StatusCode == http.StatusGone || resp.StatusCode >= 500 {
			resp.Body.Close()
			return nil, "", &sourceUnavailableError{reason: fmt.Sprintf("HTTP %d", resp.StatusCode)}
		}
		if resp.StatusCode != http.StatusOK {
			resp.Body.Close()
			return nil, "", fmt.Errorf("%s returned HTTP %d", current, resp.StatusCode)
		}
		if resp.ContentLength > HostDownloadByteLimit {
			resp.Body.Close()
			return nil, "", fmt.Errorf("%s exceeds the %d-byte download limit", current, HostDownloadByteLimit)
		}
		body, err := io.ReadAll(io.LimitReader(resp.Body, HostDownloadByteLimit+1))
		resp.Body.Close()
		if err != nil {
			return nil, "", err
		}
		if len(body) > HostDownloadByteLimit {
			return nil, "", fmt.Errorf("%s exceeds the %d-byte download limit", current, HostDownloadByteLimit)
		}
		return body, current, nil
	}
	panic("unreachable")
}

func hasURLPassword(user *url.Userinfo) bool {
	_, set := user.Password()
	return set
}

func sameHTTPSOrigin(a, b *url.URL) bool {
	if a == nil || b == nil || a.Scheme != "https" || b.Scheme != "https" || !strings.EqualFold(a.Hostname(), b.Hostname()) {
		return false
	}
	port := func(value *url.URL) string {
		if value.Port() == "" {
			return "443"
		}
		n, err := strconv.Atoi(value.Port())
		if err != nil {
			return value.Port()
		}
		return strconv.Itoa(n)
	}
	return port(a) == port(b)
}

func pathInside(root, child string) bool {
	rel, err := filepath.Rel(root, child)
	return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) && !filepath.IsAbs(rel)
}

func vendorComponentDownload(filePath string, body []byte) ([]byte, error) {
	root, err := filepath.EvalSymlinks(".")
	if err != nil {
		return nil, err
	}
	root, err = filepath.Abs(root)
	if err != nil {
		return nil, err
	}
	parent := filepath.Dir(filePath)
	ancestor := parent
	for {
		resolved, resolveErr := filepath.EvalSymlinks(ancestor)
		if resolveErr == nil {
			resolved, _ = filepath.Abs(resolved)
			if !pathInside(root, resolved) {
				return nil, fmt.Errorf("refusing to vendor outside the current directory: %s", filePath)
			}
			break
		}
		if !errors.Is(resolveErr, os.ErrNotExist) {
			return nil, resolveErr
		}
		next := filepath.Dir(ancestor)
		if next == ancestor {
			return nil, resolveErr
		}
		ancestor = next
	}
	if err := os.MkdirAll(parent, 0o755); err != nil {
		return nil, err
	}
	resolvedParent, err := filepath.EvalSymlinks(parent)
	if err != nil {
		return nil, err
	}
	resolvedParent, _ = filepath.Abs(resolvedParent)
	if !pathInside(root, resolvedParent) {
		return nil, fmt.Errorf("refusing to vendor outside the current directory: %s", filePath)
	}
	random := make([]byte, 12)
	if _, err := rand.Read(random); err != nil {
		return nil, err
	}
	temporaryPath := filepath.Join(parent, "."+filepath.Base(filePath)+".qip-"+strconv.Itoa(os.Getpid())+"-"+hex.EncodeToString(random)+".tmp")
	f, err := os.OpenFile(temporaryPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		return nil, err
	}
	_, writeErr := f.Write(body)
	closeErr := f.Close()
	defer os.Remove(temporaryPath)
	if writeErr != nil {
		return nil, writeErr
	}
	if closeErr != nil {
		return nil, closeErr
	}
	if err := os.Link(temporaryPath, filePath); err != nil && !errors.Is(err, os.ErrExist) {
		return nil, err
	}
	return os.ReadFile(filePath)
}
