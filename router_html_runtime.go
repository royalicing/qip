package main

import (
	_ "embed"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"sort"
	"strings"
)

func injectQIPFormRuntime(body []byte, formModules map[string][]byte, formDigests map[string][32]byte) ([]byte, [][32]byte, error) {
	formNames, err := extractQIPFormNames(body)
	if err != nil {
		return nil, nil, err
	}
	if len(formNames) == 0 {
		return body, nil, nil
	}
	if len(formModules) == 0 {
		return nil, nil, errors.New("qip-form tags detected, but no form components are loaded (pass --forms <forms_dir>)")
	}

	usedDigests := make([][32]byte, len(formNames))
	for i, name := range formNames {
		if _, ok := formModules[name]; !ok {
			return nil, nil, fmt.Errorf("qip-form name %q has no matching module in --forms", name)
		}
		digest, ok := formDigests[name]
		if !ok {
			return nil, nil, fmt.Errorf("qip-form name %q is missing digest metadata", name)
		}
		usedDigests[i] = digest
	}

	script, err := buildQIPFormInlineScript(formNames, formModules)
	if err != nil {
		return nil, nil, err
	}
	return injectInlineModuleScript(body, script), usedDigests, nil
}

func extractQIPFormNames(body []byte) ([]string, error) {
	tags := qipFormTagPattern.FindAll(body, -1)
	if len(tags) == 0 {
		return nil, nil
	}

	seen := make(map[string]struct{}, len(tags))
	names := make([]string, 0, len(tags))
	for _, tagBytes := range tags {
		matches := qipFormNamePattern.FindSubmatch(tagBytes)
		if len(matches) == 0 {
			return nil, errors.New("<qip-form> tag is missing required name attribute")
		}

		var rawName string
		for i := 1; i <= 3; i++ {
			if len(matches[i]) > 0 {
				rawName = string(matches[i])
				break
			}
		}
		name := strings.TrimSpace(html.UnescapeString(rawName))
		if name == "" {
			return nil, errors.New("<qip-form> name attribute must not be empty")
		}
		if _, ok := seen[name]; ok {
			continue
		}
		seen[name] = struct{}{}
		names = append(names, name)
	}

	sort.Strings(names)
	return names, nil
}

func buildQIPFormInlineScript(formNames []string, formModules map[string][]byte) ([]byte, error) {
	var b strings.Builder
	b.Grow(4096 + len(formNames)*256)
	b.WriteString("<script type=\"module\">\n")
	b.WriteString("const qipFormModules = new Map([\n")
	for _, name := range formNames {
		moduleBytes := formModules[name]
		nameJSON, err := json.Marshal(name)
		if err != nil {
			return nil, err
		}
		encodedJSON, err := json.Marshal(base64.StdEncoding.EncodeToString(moduleBytes))
		if err != nil {
			return nil, err
		}
		b.WriteString("  [")
		b.Write(nameJSON)
		b.WriteString(", ")
		b.Write(encodedJSON)
		b.WriteString("],\n")
	}
	b.WriteString("]);\n")
	b.WriteString(qipFormClientRuntimeModuleJS)
	b.WriteString("\n</script>")
	return []byte(b.String()), nil
}

func injectInlineModuleScript(body []byte, script []byte) []byte {
	lower := strings.ToLower(string(body))
	idx := strings.LastIndex(lower, "</body>")
	if idx == -1 {
		out := make([]byte, 0, len(body)+len(script))
		out = append(out, body...)
		out = append(out, script...)
		return out
	}

	out := make([]byte, 0, len(body)+len(script))
	out = append(out, body[:idx]...)
	out = append(out, script...)
	out = append(out, body[idx:]...)
	return out
}

func injectQIPEditRuntime(body []byte) []byte {
	if !qipEditTagPattern.Match(body) {
		return body
	}
	var b strings.Builder
	b.Grow(len(qipEditClientRuntimeModuleJS) + 64)
	b.WriteString("<script type=\"module\">\n")
	b.WriteString(qipEditClientRuntimeModuleJS)
	b.WriteString("\n</script>")
	return injectInlineModuleScript(body, []byte(b.String()))
}

func injectQIPPlayRuntime(body []byte) []byte {
	if !qipPlayTagPattern.Match(body) {
		return body
	}
	var b strings.Builder
	b.Grow(len(qipPlayClientRuntimeModuleJS) + 64)
	b.WriteString("<script type=\"module\">\n")
	b.WriteString(qipPlayClientRuntimeModuleJS)
	b.WriteString("\n</script>")
	return injectInlineModuleScript(body, []byte(b.String()))
}

//go:embed embedded/qip-form-client-runtime.js
var qipFormClientRuntimeModuleJS string

//go:embed embedded/qip-edit-client-runtime.js
var qipEditClientRuntimeModuleJS string

//go:embed embedded/qip-play-client-runtime.js
var qipPlayClientRuntimeModuleJS string
