module github.com/xocketlabs/bupsy.si/tools/bupsy-run

go 1.24

// No dependencies, and that is a decision rather than an accident. This module spawns other
// people's binaries and parses their output; the standard library covers all of it. A supply chain
// is a thing that can be compromised between us and a user's machine, so this one stays empty.
