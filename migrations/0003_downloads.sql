-- Downloads: the same list, now filled by the download form. `updates` is 1 only when the person
-- ticked "one email a month about what's new"; without it they get no email from us at all.
-- `downloads` counts how many times that address started the download, the closest honest
-- measure of real users without putting telemetry in the app.
ALTER TABLE waitlist ADD COLUMN updates INTEGER NOT NULL DEFAULT 0;
ALTER TABLE waitlist ADD COLUMN downloads INTEGER NOT NULL DEFAULT 0;
ALTER TABLE waitlist ADD COLUMN last_download_at TEXT;
