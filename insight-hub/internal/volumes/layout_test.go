package volumes

import (
	"os"
	"path/filepath"
	"testing"
)

func TestFromEnvDefaults(t *testing.T) {
	os.Clearenv()
	l := FromEnv()
	if l.Data != "/data" || l.Checkpoint != "/checkpoint" || l.Cache != "/cache" || l.Output != "/output" {
		t.Fatalf("defaults: %+v", l)
	}
}

func TestEnsureWorkDirs(t *testing.T) {
	root := t.TempDir()
	l := Layout{
		Data:       filepath.Join(root, "data"),
		Checkpoint: filepath.Join(root, "cp"),
		Cache:      filepath.Join(root, "cache"),
		Output:     filepath.Join(root, "out"),
	}
	if err := l.EnsureWorkDirs(); err != nil {
		t.Fatal(err)
	}
	for _, sub := range []string{"cp", "cache", "out"} {
		st, err := os.Stat(filepath.Join(root, sub))
		if err != nil || !st.IsDir() {
			t.Fatalf("missing dir %s: %v", sub, err)
		}
	}
}
