package client

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"time"
)

// watch uses a portable, dependency-free polling loop. It rebuilds only the
// changed service, preserving volumes and the other running containers.
func runWatch(ctx context.Context, cfg *Config, args []string, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("watch", flag.ContinueOnError)
	flags.SetOutput(stderr)
	var file, service string
	flags.StringVar(&file, "f", "okestra.json", "project manifest")
	flags.StringVar(&service, "service", "", "watch only this service")
	if err := flags.Parse(args); err != nil || flags.NArg() != 0 {
		fmt.Fprintln(stderr, "usage: okestra watch [-f okestra.json] [--service name]")
		return 1
	}
	p, base, order, err := loadProject(file)
	if err != nil {
		fmt.Fprintf(stderr, "project: %v\n", err)
		return 1
	}
	builds := map[string]string{}
	for _, name := range order {
		if service != "" && service != name {
			continue
		}
		if b := p.Services[name].Build; b != nil {
			path, err := localProjectPath(base, b.Context)
			if err != nil {
				fmt.Fprintln(stderr, err)
				return 1
			}
			builds[name] = path
		}
	}
	if len(builds) == 0 {
		fmt.Fprintln(stderr, "no build services selected; watch needs a local build context")
		return 1
	}
	if code := runProjectUp(ctx, cfg, []string{"-f", file}, stdout, stderr); code != 0 {
		return code
	}
	last := map[string]string{}
	for name, path := range builds {
		digest, err := contextDigest(path)
		if err != nil {
			fmt.Fprintf(stderr, "watch %s: %v\n", name, err)
			return 1
		}
		last[name] = digest
	}
	fmt.Fprintln(stdout, "watching source for changes (Ctrl-C to stop)")
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return 0
		case <-ticker.C:
		}
		names := make([]string, 0, len(builds))
		for name := range builds {
			names = append(names, name)
		}
		sort.Strings(names)
		for _, name := range names {
			digest, err := contextDigest(builds[name])
			if err != nil {
				fmt.Fprintf(stderr, "watch %s: %v\n", name, err)
				continue
			}
			if digest == last[name] {
				continue
			}
			// Debounce editor writes and atomic renames.
			select {
			case <-ctx.Done():
				return 0
			case <-time.After(500 * time.Millisecond):
			}
			digest, err = contextDigest(builds[name])
			if err != nil {
				fmt.Fprintf(stderr, "watch %s: %v\n", name, err)
				continue
			}
			fmt.Fprintf(stdout, "change detected in %s; rebuilding...\n", name)
			if runProjectUp(ctx, cfg, []string{"-f", file, "--service", name, "--build", "--recreate"}, stdout, stderr) != 0 {
				fmt.Fprintf(stderr, "%s rebuild failed; watching for the next change\n", name)
			}
			last[name] = digest
		}
	}
}

func contextDigest(root string) (string, error) {
	ignore, err := LoadDockerignore(root)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	if ignore == nil {
		ignore = &Dockerignore{}
	}
	h := sha256.New()
	files := 0
	err = filepath.WalkDir(root, func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		if rel == "." {
			return nil
		}
		if d.IsDir() && (d.Name() == ".git" || d.Name() == ".okestra") {
			return filepath.SkipDir
		}
		if ignore.ShouldIgnore(rel, d.IsDir()) {
			if d.IsDir() && ignore.CanSkipIgnoredDir() {
				return filepath.SkipDir
			}
			if !d.IsDir() {
				return nil
			}
		}
		if d.IsDir() {
			return nil
		}
		if !d.Type().IsRegular() {
			return nil
		}
		files++
		if files > 50000 {
			return errors.New("watch context exceeds 50000 files; add .dockerignore rules")
		}
		_, _ = io.WriteString(h, filepath.ToSlash(rel)+"\x00")
		f, err := os.Open(path)
		if err != nil {
			return err
		}
		_, err = io.Copy(h, f)
		f.Close()
		if err != nil {
			return err
		}
		_, _ = io.WriteString(h, "\x00")
		return nil
	})
	if err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}
