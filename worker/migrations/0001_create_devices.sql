CREATE TABLE devices (
    device_id TEXT PRIMARY KEY NOT NULL,
    apns_token TEXT,
    apns_environment TEXT,
    platform TEXT NOT NULL DEFAULT 'ios',
    app_version TEXT,
    system_version TEXT,
    device_model TEXT,
    first_seen_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_seen_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    token_updated_at TEXT,
    CHECK (
        (apns_token IS NULL AND apns_environment IS NULL)
        OR (
            apns_token IS NOT NULL
            AND length(apns_token) > 0
            AND apns_environment IS NOT NULL
            AND apns_environment IN ('development', 'production')
        )
    )
);
