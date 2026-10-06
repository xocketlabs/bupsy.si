package engine

import (
	"fmt"
	"strings"
)

// The trust ladder, lowest first. The same four names as the Swift core's Autonomy enum
// (Packages/BupsyKit/Sources/BupsyKit/Engines/EngineAdapter.swift), because a bot's setting is
// stored once and read by both cores — a name only one of them knows is a bot whose trust level
// silently means different things depending on where it runs.
const (
	AutonomyAsk       = "ask"
	AutonomyAllowlist = "allowlist"
	AutonomyTrusted   = "trusted"
	AutonomyAuto      = "auto"
)

// Autonomies lists every trust level, lowest first.
var Autonomies = []string{AutonomyAsk, AutonomyAllowlist, AutonomyTrusted, AutonomyAuto}

// CheckAutonomy refuses a trust level that is not on the ladder.
//
// The adapters already treat an unknown level as the most restrictive one, which is the right
// last line of defence. But a typo at the command line ("write", say, from an older flag
// description) should be an error the person sees, not a run that quietly behaves differently
// from what they asked for.
func CheckAutonomy(autonomy string) error {
	for _, known := range Autonomies {
		if autonomy == known {
			return nil
		}
	}
	return fmt.Errorf("unknown autonomy %q (want one of: %s)", autonomy, strings.Join(Autonomies, ", "))
}
