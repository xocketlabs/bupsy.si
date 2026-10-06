package cron

import (
	"testing"
	"time"
)

func at(t *testing.T, value string) time.Time {
	t.Helper()
	parsed, err := time.ParseInLocation("2006-01-02 15:04", value, time.UTC)
	if err != nil {
		t.Fatal(err)
	}
	return parsed
}

// Day of month and day of week are ORed when both are restricted, as in every cron since Vixie's.
// 2026-06-01 is a Monday; 2026-06-08 a Monday; 2026-07-01 a Wednesday; 2026-06-02 a Tuesday.
func TestDayFieldsFollowCronsOrRule(t *testing.T) {
	cases := []struct {
		expression, moment string
		want               bool
		why                string
	}{
		{"0 9 1 * 1", "2026-06-08 09:00", true, "a Monday that is not the 1st: both restricted, so either fires"},
		{"0 9 1 * 1", "2026-07-01 09:00", true, "the 1st on a Wednesday: both restricted, so either fires"},
		{"0 9 1 * 1", "2026-06-02 09:00", false, "neither the 1st nor a Monday"},
		{"0 9 1 * 1", "2026-06-08 10:00", false, "the right day at the wrong hour still does not fire"},
		{"0 9 * * 1", "2026-06-02 09:00", false, "only weekday restricted: Tuesdays do not fire"},
		{"0 9 * * 1", "2026-06-08 09:00", true, "only weekday restricted: Mondays fire"},
		{"0 9 1 * *", "2026-06-08 09:00", false, "only day of month restricted: the 8th does not fire"},
		{"0 9 1 * *", "2026-07-01 09:00", true, "only day of month restricted: the 1st fires"},
		{"0 9 15 6 1", "2026-07-06 09:00", false, "a July Monday: the month still has to match"},
		{"0 9 * * 0-6", "2026-06-02 09:00", true, "a full weekday range is every day, not a restriction"},
	}
	for _, c := range cases {
		expression, err := Parse(c.expression)
		if err != nil {
			t.Fatalf("parse %q: %v", c.expression, err)
		}
		if got := expression.Matches(at(t, c.moment)); got != c.want {
			t.Errorf("%q at %s = %v, want %v — %s", c.expression, c.moment, got, c.want, c.why)
		}
	}
}

// The AND reading made "1st and Mondays" wait for a Monday the 1st, months away.
func TestNextFireUsesTheOrRule(t *testing.T) {
	expression, err := Parse("0 9 1 * 1")
	if err != nil {
		t.Fatal(err)
	}
	next, ok := expression.NextFire(at(t, "2026-06-02 09:00"))
	if !ok {
		t.Fatal("no next fire")
	}
	if want := at(t, "2026-06-08 09:00"); !next.Equal(want) {
		t.Errorf("next fire = %s, want %s (the following Monday)", next, want)
	}
}
