-- Discovered while migrating real production data: activity_log.tracker was typed
-- as the strict 5-value tracker_kind enum, but the real Transactions data uses it
-- as a free-text activity-category label (e.g. "Sterilisation", "Implants",
-- "Requests"), not just the 5 stock trackers. Relaxing to plain text.
alter table activity_log alter column tracker type text;
