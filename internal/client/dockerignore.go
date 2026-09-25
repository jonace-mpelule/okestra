package client

import (
	"bufio"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

type Dockerignore struct {
	patterns     []dockerignorePattern
	hasNegations bool
}

type dockerignorePattern struct {
	match   *regexp.Regexp
	negated bool
}

func LoadDockerignore(root string) (*Dockerignore, error) {
	path := filepath.Join(root, ".dockerignore")
	f, err := os.Open(path)
	if err != nil {
		return &Dockerignore{}, err
	}
	defer f.Close()

	var patterns []dockerignorePattern
	hasNegations := false
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		negated := strings.HasPrefix(line, "!")
		if negated {
			line = strings.TrimSpace(strings.TrimPrefix(line, "!"))
			hasNegations = true
		}
		line = strings.Trim(strings.TrimSuffix(filepath.ToSlash(line), "/"), "/")
		if line == "" || line == "." {
			continue
		}
		compiled, err := regexp.Compile(dockerignoreRegexp(line))
		if err != nil {
			return nil, err
		}
		patterns = append(patterns, dockerignorePattern{match: compiled, negated: negated})
	}
	return &Dockerignore{patterns: patterns, hasNegations: hasNegations}, scanner.Err()
}

func (d *Dockerignore) ShouldIgnore(relPath string, _ bool) bool {
	relPath = filepath.ToSlash(relPath)
	ignored := false
	for _, pattern := range d.patterns {
		if pattern.match.MatchString(relPath) {
			ignored = !pattern.negated
		}
	}
	return ignored
}

func (d *Dockerignore) CanSkipIgnoredDir() bool {
	return !d.hasNegations
}

func dockerignoreRegexp(pattern string) string {
	var out strings.Builder
	if strings.Contains(pattern, "/") {
		out.WriteString("^")
	} else {
		out.WriteString("(?:^|/)")
	}
	for i := 0; i < len(pattern); i++ {
		switch pattern[i] {
		case '*':
			if i+1 < len(pattern) && pattern[i+1] == '*' {
				out.WriteString(".*")
				i++
			} else {
				out.WriteString("[^/]*")
			}
		case '?':
			out.WriteString("[^/]")
		default:
			out.WriteString(regexp.QuoteMeta(string(pattern[i])))
		}
	}
	out.WriteString("(?:/.*)?$")
	return out.String()
}
