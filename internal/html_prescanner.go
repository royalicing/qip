package qinternal

import (
	"bytes"
	"html"
	"net/url"
	"strings"
)

func prescanHTMLSourcePaths(body []byte, documentPath string) []string {
	base := &url.URL{Path: documentPath}
	paths := make([]string, 0)
	seen := make(map[string]struct{})
	for offset := 0; offset < len(body); {
		lt := bytes.IndexByte(body[offset:], '<')
		if lt < 0 {
			break
		}
		lt += offset
		if bytes.HasPrefix(body[lt:], []byte("<!--")) {
			end := bytes.Index(body[lt+4:], []byte("-->"))
			if end < 0 {
				break
			}
			offset = lt + 4 + end + 3
			continue
		}
		tagEnd := scanHTMLTagEnd(body, lt+1)
		if tagEnd < 0 {
			break
		}
		tag := body[lt+1 : tagEnd]
		tagName, closing := scanHTMLTagName(tag)
		if tagName == "" || closing {
			offset = tagEnd + 1
			continue
		}
		for _, value := range scanHTMLTagSourceAttributes(tag) {
			ref, err := url.Parse(html.UnescapeString(value))
			if err != nil || ref.Scheme != "" || ref.Host != "" {
				continue
			}
			resolved := base.ResolveReference(ref)
			if resolved.Scheme != "" || resolved.Host != "" || resolved.Path == "" || !strings.HasPrefix(resolved.Path, "/") {
				continue
			}
			if _, ok := seen[resolved.Path]; ok {
				continue
			}
			seen[resolved.Path] = struct{}{}
			paths = append(paths, resolved.Path)
		}
		offset = tagEnd + 1
		if tagName == "plaintext" {
			break
		}
		if isHTMLRawTextElement(tagName) {
			if end := indexHTMLRawTextEnd(body[offset:], tagName); end >= 0 {
				offset += end
			} else {
				break
			}
		}
	}
	return paths
}

func scanHTMLTagName(tag []byte) (string, bool) {
	i := 0
	for i < len(tag) && isHTMLSpace(tag[i]) {
		i++
	}
	closing := i < len(tag) && tag[i] == '/'
	if closing {
		i++
		for i < len(tag) && isHTMLSpace(tag[i]) {
			i++
		}
	}
	start := i
	for i < len(tag) && isHTMLNameByte(tag[i]) {
		i++
	}
	if start == i {
		return "", closing
	}
	return strings.ToLower(string(tag[start:i])), closing
}

func isHTMLRawTextElement(tagName string) bool {
	switch tagName {
	case "script", "style", "textarea", "title", "xmp", "iframe", "noembed", "noframes":
		return true
	default:
		return false
	}
}

func indexHTMLRawTextEnd(haystack []byte, tagName string) int {
	needle := []byte("</" + tagName)
	for i := 0; i+len(needle) < len(haystack); i++ {
		matched := true
		for j := range needle {
			a, b := haystack[i+j], needle[j]
			if a >= 'A' && a <= 'Z' {
				a += 'a' - 'A'
			}
			if b >= 'A' && b <= 'Z' {
				b += 'a' - 'A'
			}
			if a != b {
				matched = false
				break
			}
		}
		if matched && (isHTMLSpace(haystack[i+len(needle)]) || haystack[i+len(needle)] == '/' || haystack[i+len(needle)] == '>') {
			return i
		}
	}
	return -1
}

func scanHTMLTagEnd(body []byte, start int) int {
	quote := byte(0)
	for i := start; i < len(body); i++ {
		switch body[i] {
		case '\'', '"':
			if quote == 0 {
				quote = body[i]
			} else if quote == body[i] {
				quote = 0
			}
		case '>':
			if quote == 0 {
				return i
			}
		}
	}
	return -1
}

func scanHTMLTagSourceAttributes(tag []byte) []string {
	values := make([]string, 0, 1)
	i := 0
	for i < len(tag) && (isHTMLSpace(tag[i]) || tag[i] == '/') {
		i++
	}
	for i < len(tag) && isHTMLNameByte(tag[i]) {
		i++
	}
	for i < len(tag) {
		for i < len(tag) && (isHTMLSpace(tag[i]) || tag[i] == '/') {
			i++
		}
		nameStart := i
		for i < len(tag) && isHTMLNameByte(tag[i]) {
			i++
		}
		if nameStart == i {
			i++
			continue
		}
		name := tag[nameStart:i]
		for i < len(tag) && isHTMLSpace(tag[i]) {
			i++
		}
		if i >= len(tag) || tag[i] != '=' {
			continue
		}
		i++
		for i < len(tag) && isHTMLSpace(tag[i]) {
			i++
		}
		valueStart := i
		valueEnd := i
		if i < len(tag) && (tag[i] == '\'' || tag[i] == '"') {
			quote := tag[i]
			i++
			valueStart = i
			for i < len(tag) && tag[i] != quote {
				i++
			}
			valueEnd = i
			if i < len(tag) {
				i++
			}
		} else {
			valueStart = i
			for i < len(tag) && !isHTMLSpace(tag[i]) {
				i++
			}
			valueEnd = i
		}
		if len(name) == 3 && strings.EqualFold(string(name), "src") && valueEnd > valueStart {
			values = append(values, string(tag[valueStart:valueEnd]))
		}
	}
	return values
}

func isHTMLSpace(ch byte) bool {
	switch ch {
	case ' ', '\t', '\n', '\r', '\f':
		return true
	default:
		return false
	}
}

func isHTMLNameByte(ch byte) bool {
	return ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || ch == '-' || ch == '_' || ch == ':'
}
