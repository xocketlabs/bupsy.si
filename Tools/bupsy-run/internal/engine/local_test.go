package engine

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"
)

const (
	ollamaTags     = `{"models":[{"name":"qwen3:8b","size":5225388164},{"name":"nomic-embed-text:latest"}]}`
	lmstudioModels = `{"object":"list","data":[{"id":"qwen/qwen3-8b","object":"model"},{"id":"text-embedding-nomic-embed-text-v1.5"}]}`
)

// fakeFetch serves the given bodies by port and fails like a closed port for the rest.
func fakeFetch(ollama, lmstudio string) func(context.Context, string) ([]byte, error) {
	return func(_ context.Context, url string) ([]byte, error) {
		switch {
		case strings.Contains(url, ":11434/") && ollama != "":
			return []byte(ollama), nil
		case strings.Contains(url, ":1234/") && lmstudio != "":
			return []byte(lmstudio), nil
		}
		return nil, errors.New("connection refused")
	}
}

// The argv is pinned by conformance/cases/local-command, shared with the Swift core. These pin
// what that format cannot: the runs that must never reach codex at all.
func TestLocalRefusesWithoutAProviderAndModel(t *testing.T) {
	for _, model := range []string{"", "qwen3:8b", "llama:3", "ollama:"} {
		name, args := Local{}.Command(Request{Prompt: "hi", Model: model, Autonomy: AutonomyAsk})
		if name != "" || args != nil {
			t.Errorf("model %q: got %s %v, want no command (codex --oss without -m downloads a model)", model, name, args)
		}
	}
}

func TestLocalFlagsGoBeforeResume(t *testing.T) {
	_, args := Local{}.Command(Request{Prompt: "-x", Model: "ollama:qwen3:8b", Autonomy: AutonomyAsk, Resume: "t-1"})
	want := []string{"exec", "--json", "--oss", "--local-provider", "ollama", "--sandbox", "read-only",
		"--skip-git-repo-check", "-m", "qwen3:8b", "resume", "t-1", "--", "-x"}
	if !reflect.DeepEqual(args, want) {
		t.Errorf("argv:\n  got  %v\n  want %v", args, want)
	}
}

func TestLocalModelNamesForBothProviders(t *testing.T) {
	if got, _ := LocalModelNames("ollama", []byte(ollamaTags)); !reflect.DeepEqual(got, []string{"qwen3:8b"}) {
		t.Errorf("ollama: got %v", got)
	}
	if got, _ := LocalModelNames("lmstudio", []byte(lmstudioModels)); !reflect.DeepEqual(got, []string{"qwen/qwen3-8b"}) {
		t.Errorf("lmstudio: got %v", got)
	}
	if _, err := LocalModelNames("ollama", []byte(lmstudioModels)); err == nil {
		t.Error("an LM Studio reply was read as Ollama's")
	}
}

func TestLocalPrepareOnlyRunsAnInstalledModel(t *testing.T) {
	both := Local{Fetch: fakeFetch(ollamaTags, lmstudioModels)}
	cases := []struct {
		local         Local
		model, want   string
		errorContains string
	}{
		{both, "ollama:qwen3:8b", "ollama:qwen3:8b", ""},
		{both, "qwen/qwen3-8b", "lmstudio:qwen/qwen3-8b", ""},
		{both, "", "", "pick a model"},
		{both, "ollama:gpt-oss:20b", "", "isn't installed in Ollama"},
		{both, "llama3", "", "isn't installed in Ollama or LM Studio"},
		{Local{Fetch: fakeFetch("", "")}, "ollama:qwen3:8b", "", "start Ollama or LM Studio"},
		{Local{Fetch: fakeFetch("", lmstudioModels)}, "ollama:qwen3:8b", "", "Ollama isn't running"},
	}
	for _, c := range cases {
		got, err := c.local.Prepare(context.Background(), Request{Model: c.model})
		if c.errorContains != "" {
			if err == nil || !strings.Contains(err.Error(), c.errorContains) {
				t.Errorf("model %q: err = %v, want one containing %q", c.model, err, c.errorContains)
			}
			continue
		}
		if err != nil || got.Model != c.want {
			t.Errorf("model %q: got %q, %v; want %q", c.model, got.Model, err, c.want)
		}
	}
}

func TestLocalSurfacesCodexRuntimeCheck(t *testing.T) {
	events := Local{}.NormaliseStderr("Error: OSS setup failed: No running Ollama server detected. Start it with: `ollama serve` (after installing).")
	if len(events) != 1 || events[0].Kind != KindFailed || !strings.HasPrefix(events[0].Message, "No running Ollama server") {
		t.Errorf("got %v", events)
	}
}

func TestLocalDropsCodexFallbackMetadataWarning(t *testing.T) {
	warning := `{"type":"item.completed","item":{"id":"item_0","type":"error","message":"Model metadata for ` + "`qwen3:8b`" + ` not found. Defaulting to fallback metadata; this can degrade performance and cause issues."}}`
	if events := (Local{}).Normalise(warning); len(events) != 0 {
		t.Fatalf("the fallback-metadata warning must not be an event, got %+v", events)
	}
	other := `{"type":"item.completed","item":{"id":"item_1","type":"error","message":"stream disconnected before completion"}}`
	events := (Local{}).Normalise(other)
	if len(events) != 1 || events[0].Kind != KindFailed || events[0].Message != "stream disconnected before completion" {
		t.Fatalf("any other error item stays a failure, got %+v", events)
	}
}
