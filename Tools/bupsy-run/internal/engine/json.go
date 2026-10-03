package engine

import "encoding/json"

// line is one parsed stdout line, held loosely.
//
// Engine stream schemas are fixture-driven rather than documented — they are read off real runs
// and can change without notice. Decoding into typed structs would fail a whole line when one
// field moved; this keeps every lookup optional so a changed shape degrades to KindUnknown
// instead of taking the run down.
type line struct {
	raw  string
	body map[string]any
}

// parse returns the line, or ok=false if it is not JSON at all. Engines print plain-text
// progress to stdout alongside the stream, so a non-JSON line is routine and not an error.
func parse(raw string) (line, bool) {
	var body map[string]any
	if err := json.Unmarshal([]byte(raw), &body); err != nil {
		return line{}, false
	}
	return line{raw: raw, body: body}, true
}

func (l line) str(key string) string {
	s, _ := l.body[key].(string)
	return s
}

func (l line) dict(key string) map[string]any {
	d, _ := l.body[key].(map[string]any)
	return d
}

func (l line) boolean(key string) (bool, bool) {
	b, ok := l.body[key].(bool)
	return b, ok
}

// blocks reads an array of objects, skipping entries that are not objects. Used for message
// content and connector lists.
func blocks(value any) []map[string]any {
	items, ok := value.([]any)
	if !ok {
		return nil
	}
	out := make([]map[string]any, 0, len(items))
	for _, item := range items {
		if m, ok := item.(map[string]any); ok {
			out = append(out, m)
		}
	}
	return out
}

func str(m map[string]any, key string) string {
	s, _ := m[key].(string)
	return s
}

// intField returns a pointer so "absent" and "zero" stay distinguishable: a run that reported
// 0 output tokens is a different fact from one that reported nothing.
func intField(m map[string]any, key string) *int {
	f, ok := m[key].(float64)
	if !ok {
		return nil
	}
	n := int(f)
	return &n
}

func floatField(m map[string]any, key string) *float64 {
	f, ok := m[key].(float64)
	if !ok {
		return nil
	}
	return &f
}

func boolField(m map[string]any, key string) bool {
	b, _ := m[key].(bool)
	return b
}

// encode renders a value as compact JSON for a tool call's arguments.
//
// Go sorts map keys when marshalling, which is what makes a tool call's arguments byte-identical
// between implementations. The conformance cases compare that string, so stable ordering is part
// of the contract rather than an incidental detail.
func encode(value any) string {
	if value == nil {
		return "{}"
	}
	data, err := json.Marshal(value)
	if err != nil {
		return "{}"
	}
	return string(data)
}
