package engine

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// Local runs a bot on a model in the person's own Ollama or LM Studio, through Codex CLI's local
// mode: `codex exec --oss --local-provider <ollama|lmstudio> -m <model>`. Everything else is the
// Codex engine's: argv order, sandbox, stream.
//
// A bot's model is stored as "<provider>:<name>" ("ollama:qwen3:8b", "lmstudio:qwen/qwen3-8b"),
// split at the first colon only. The rule that matters most: a run never starts without -m naming
// an installed model, because given --oss and no model Codex pulls gpt-oss:20b (about 13 GB) on
// its own, and given a model Ollama lacks it pulls that. So Command refuses a model with no
// provider (it returns no binary, which nothing can run), and Prepare checks the model against
// what the provider lists right now. Callers run Prepare first.
type Local struct {
	Binary string
	// Fetch GETs a localhost URL. Nil uses a plain HTTP client with a short timeout; tests set it
	// so they need no runtime and no network.
	Fetch func(ctx context.Context, url string) ([]byte, error)
}

func (l Local) ID() string { return "local" }

// LocalProviders in preference order, with the endpoint that lists each one's models.
var LocalProviders = []struct{ Name, Label, URL string }{
	{"ollama", "Ollama", "http://localhost:11434/api/tags"},
	{"lmstudio", "LM Studio", "http://localhost:1234/v1/models"},
}

// ParseLocalModel splits a stored model id into its provider and the model's own name.
func ParseLocalModel(id string) (provider, name string, ok bool) {
	provider, name, found := strings.Cut(strings.TrimSpace(id), ":")
	provider = strings.ToLower(provider)
	name = strings.TrimSpace(name)
	if !found || name == "" || (provider != "ollama" && provider != "lmstudio") {
		return "", "", false
	}
	return provider, name, true
}

func (l Local) Command(req Request) (string, []string) {
	provider, name, ok := ParseLocalModel(req.Model)
	if !ok {
		// No binary at all rather than codex with --oss and no model, which downloads one.
		return "", nil
	}
	forCodex := req
	forCodex.Model = name
	_, args := Codex{Binary: l.Binary}.Command(forCodex)
	// On exec, ahead of everything and so ahead of any `resume`, which has no --oss of its own.
	local := []string{"--oss", "--local-provider", provider}
	out := append([]string{}, args[:2]...) // "exec", "--json"
	out = append(out, local...)
	out = append(out, args[2:]...)
	return Codex{Binary: l.Binary}.binary(), out
}

// Prepare makes the model exact or refuses the run: a bare name is matched to the running provider
// that has it (Ollama first), and a model that is not installed is an error, never a download.
func (l Local) Prepare(ctx context.Context, req Request) (Request, error) {
	wanted := strings.TrimSpace(req.Model)
	if wanted == "" {
		return req, errors.New("pick a model for this bot first. Without one, Codex would start " +
			"downloading gpt-oss:20b (about 13 GB) on its own")
	}
	installed := map[string][]string{}
	running := []string{}
	for _, p := range LocalProviders {
		names, err := l.models(ctx, p.Name, p.URL)
		if err != nil {
			continue
		}
		running = append(running, p.Name)
		installed[p.Name] = names
	}
	if len(running) == 0 {
		return req, errors.New("start Ollama or LM Studio, then try again")
	}
	if provider, name, ok := ParseLocalModel(wanted); ok {
		names, up := installed[provider]
		if !up {
			return req, fmt.Errorf("%s isn't running. Start it, then try again", label(provider))
		}
		for _, have := range names {
			if strings.EqualFold(have, name) {
				req.Model = provider + ":" + have
				return req, nil
			}
		}
		return req, fmt.Errorf("%s isn't installed in %s. Get it there first, or pick a model you have", name, label(provider))
	}
	for _, provider := range running {
		for _, have := range installed[provider] {
			if strings.EqualFold(have, wanted) {
				req.Model = provider + ":" + have
				return req, nil
			}
		}
	}
	return req, fmt.Errorf("%s isn't installed in Ollama or LM Studio. Pick a model you have", wanted)
}

func label(provider string) string {
	for _, p := range LocalProviders {
		if p.Name == provider {
			return p.Label
		}
	}
	return provider
}

// models lists a provider's installed models, leaving out embedding models, which cannot chat. An
// error means it is not running (or something else answers on its port).
func (l Local) models(ctx context.Context, provider, url string) ([]string, error) {
	fetch := l.Fetch
	if fetch == nil {
		fetch = getLocalhost
	}
	body, err := fetch(ctx, url)
	if err != nil {
		return nil, err
	}
	return LocalModelNames(provider, body)
}

// LocalModelNames reads Ollama's /api/tags ({"models":[{"name":…}]}) or LM Studio's /v1/models
// ({"data":[{"id":…}]}).
func LocalModelNames(provider string, body []byte) ([]string, error) {
	var reply struct {
		Models *[]struct {
			Name string `json:"name"`
		} `json:"models"`
		Data *[]struct {
			ID string `json:"id"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &reply); err != nil {
		return nil, err
	}
	var raw []string
	switch {
	case provider == "ollama" && reply.Models != nil:
		for _, m := range *reply.Models {
			raw = append(raw, m.Name)
		}
	case provider == "lmstudio" && reply.Data != nil:
		for _, m := range *reply.Data {
			raw = append(raw, m.ID)
		}
	default:
		return nil, fmt.Errorf("not a %s reply", provider)
	}
	names := []string{}
	for _, name := range raw {
		name = strings.TrimSpace(name)
		if name != "" && !strings.Contains(strings.ToLower(name), "embed") {
			names = append(names, name)
		}
	}
	return names, nil
}

var localClient = &http.Client{Timeout: 1500 * time.Millisecond, Transport: &http.Transport{Proxy: nil}}

func getLocalhost(ctx context.Context, url string) ([]byte, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	response, err := localClient.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode/100 != 2 {
		return nil, fmt.Errorf("%s answered %d", url, response.StatusCode)
	}
	return io.ReadAll(io.LimitReader(response.Body, 4<<20))
}

func (l Local) Normalise(line string) []Event {
	if isFallbackMetadataWarning(line) {
		return nil
	}
	return Codex{}.Normalise(line)
}

// isFallbackMetadataWarning is Codex's note at the start of every local turn, sent as an error
// item: "Model metadata for `qwen3:8b` not found. Defaulting to fallback metadata; …". The turn
// goes on and answers, so it is a warning, not a failure. Seen on codex 0.160 with Ollama.
func isFallbackMetadataWarning(line string) bool {
	if !strings.Contains(line, "fallback metadata") {
		return false
	}
	var event struct {
		Type string `json:"type"`
		Item struct {
			Type    string `json:"type"`
			Message string `json:"message"`
		} `json:"item"`
	}
	if json.Unmarshal([]byte(line), &event) != nil {
		return false
	}
	return event.Type == "item.completed" && event.Item.Type == "error" &&
		strings.HasPrefix(event.Item.Message, "Model metadata for") &&
		strings.Contains(event.Item.Message, "Defaulting to fallback metadata")
}

func (l Local) NormaliseStderr(raw string) []Event {
	// Codex's own check that the runtime is up: "Error: OSS setup failed: No running Ollama server
	// detected…". It stops the run before any event, so it is the only reason the person gets.
	trimmed := strings.TrimSpace(raw)
	if i := strings.LastIndex(trimmed, "OSS setup failed: "); i >= 0 {
		return []Event{{Kind: KindFailed, FailureKind: "notSignedIn", Message: trimmed[i+len("OSS setup failed: "):]}}
	}
	return Codex{}.NormaliseStderr(raw)
}

func (l Local) Exit(code int) []Event { return Codex{}.Exit(code) }
