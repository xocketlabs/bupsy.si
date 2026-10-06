// Package cron parses the five-field schedules routines and objectives are written in.
package cron

import (
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Expression is a parsed schedule, as explicit sets rather than a pattern to re-match.
type Expression struct {
	Minutes     []int
	Hours       []int
	DaysOfMonth []int
	Months      []int
	Weekdays    []int
}

// Parse reads a five-field cron expression.
//
// Step syntax (*/n) is refused rather than approximated. Every general-purpose cron library
// accepts it, so a port built on one would silently take schedules this core rejects, and the two
// would then disagree about when a routine runs — the kind of drift nobody notices until a bot
// fires at the wrong time. Refusing loudly keeps the implementations honest.
func Parse(expression string) (Expression, error) {
	fields := strings.Fields(expression)
	if len(fields) != 5 {
		return Expression{}, fmt.Errorf("expected five fields, got %d", len(fields))
	}
	if strings.Contains(expression, "/") {
		return Expression{}, fmt.Errorf("step syntax (*/n) is not supported; use an explicit list")
	}

	minutes, err := parseField(fields[0], 0, 59)
	if err != nil {
		return Expression{}, err
	}
	hours, err := parseField(fields[1], 0, 23)
	if err != nil {
		return Expression{}, err
	}
	days, err := parseField(fields[2], 1, 31)
	if err != nil {
		return Expression{}, err
	}
	months, err := parseField(fields[3], 1, 12)
	if err != nil {
		return Expression{}, err
	}
	weekdays, err := parseField(fields[4], 0, 7)
	if err != nil {
		return Expression{}, err
	}
	// cron spells Sunday both 0 and 7; normalise at the edge so nothing downstream has to know.
	normalised := map[int]bool{}
	for _, day := range weekdays {
		if day == 7 {
			day = 0
		}
		normalised[day] = true
	}

	return Expression{
		Minutes:     minutes,
		Hours:       hours,
		DaysOfMonth: days,
		Months:      months,
		Weekdays:    sorted(normalised),
	}, nil
}

func parseField(field string, low, high int) ([]int, error) {
	values := map[int]bool{}
	if field == "*" {
		for value := low; value <= high; value++ {
			values[value] = true
		}
		return sorted(values), nil
	}

	for _, part := range strings.Split(field, ",") {
		if strings.Contains(part, "-") {
			bounds := strings.Split(part, "-")
			if len(bounds) != 2 {
				return nil, fmt.Errorf("bad range %q", part)
			}
			from, errFrom := strconv.Atoi(bounds[0])
			to, errTo := strconv.Atoi(bounds[1])
			if errFrom != nil || errTo != nil || from > to || from < low || to > high {
				return nil, fmt.Errorf("bad range %q", part)
			}
			for value := from; value <= to; value++ {
				values[value] = true
			}
			continue
		}
		value, err := strconv.Atoi(part)
		if err != nil || value < low || value > high {
			return nil, fmt.Errorf("bad value %q", part)
		}
		values[value] = true
	}
	return sorted(values), nil
}

func sorted(set map[int]bool) []int {
	out := make([]int, 0, len(set))
	for value := range set {
		out = append(out, value)
	}
	sort.Ints(out)
	return out
}

// Matches reports whether this moment fires. Minute resolution, which is all cron promises.
//
// Day of month and day of week follow cron's own rule, which is not the obvious one: when BOTH are
// restricted, a day matching EITHER fires. "0 9 1 * 1" is the 1st of the month and every Monday,
// not only Mondays that fall on the 1st — which is what an AND gives, and which fires a few times
// a year instead of every week. When only one is restricted, the other is every day, so AND and OR
// agree and the restricted one decides.
//
// "Restricted" is read from the sets: a field that covers every day it can is unrestricted. Classic
// cron decides by whether the field was written starting with "*", so the two differ only for a
// full range spelled out ("1-31", "0-6"), which nobody writes to mean anything but "every day".
func (e Expression) Matches(at time.Time) bool {
	if !contains(e.Minutes, at.Minute()) ||
		!contains(e.Hours, at.Hour()) ||
		!contains(e.Months, int(at.Month())) {
		return false
	}
	dayOfMonth := contains(e.DaysOfMonth, at.Day())
	dayOfWeek := contains(e.Weekdays, int(at.Weekday()))
	if e.restrictsDayOfMonth() && e.restrictsWeekday() {
		return dayOfMonth || dayOfWeek
	}
	return dayOfMonth && dayOfWeek
}

// restrictsDayOfMonth reports whether the day-of-month field leaves out any day.
func (e Expression) restrictsDayOfMonth() bool { return !coversAll(e.DaysOfMonth, 1, 31) }

// restrictsWeekday reports whether the day-of-week field leaves out any day.
func (e Expression) restrictsWeekday() bool { return !coversAll(e.Weekdays, 0, 6) }

func coversAll(values []int, low, high int) bool {
	for value := low; value <= high; value++ {
		if !contains(values, value) {
			return false
		}
	}
	return true
}

// NextFire returns the next firing strictly after at, searching minute by minute for up to a year.
// The bound matters: an expression like "0 0 30 2 *" never fires, and an unbounded search would
// hang the scheduler rather than report that.
func (e Expression) NextFire(after time.Time) (time.Time, bool) {
	candidate := after.Truncate(time.Minute).Add(time.Minute)
	for i := 0; i < 366*24*60; i++ {
		if e.Matches(candidate) {
			return candidate, true
		}
		candidate = candidate.Add(time.Minute)
	}
	return time.Time{}, false
}

func contains(values []int, value int) bool {
	for _, candidate := range values {
		if candidate == value {
			return true
		}
	}
	return false
}
