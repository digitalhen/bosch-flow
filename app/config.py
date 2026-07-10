"""Static configuration for the Bosch eBike Flow facade."""

# --- OAuth (Bosch Keycloak, realm 'obc') ------------------------------------
AUTH_URL = "https://p9.authz.bosch.com/auth/realms/obc/protocol/openid-connect/auth"
TOKEN_URL = "https://p9.authz.bosch.com/auth/realms/obc/protocol/openid-connect/token"
CLIENT_ID = "one-bike-app"
REDIRECT_URI = "onebikeapp-ios://com.bosch.ebike.onebikeapp/oauth2redirect"
SCOPE = "openid offline_access"

# --- Backend service hosts (all <service>.prod.connected-biking.cloud) -------
HOST_PROFILE = "https://obc-rider-profile.prod.connected-biking.cloud"
HOST_ACTIVITY = "https://obc-rider-activity.prod.connected-biking.cloud"

# --- Cache TTLs (seconds) — respect Bosch's ~5-min ConnectModule cadence ----
TTL_LIVE = 300      # state-of-charge / battery
TTL_PROFILE = 900   # hardware/firmware/per-mode stats (rarely change)
TTL_RIDES = 600     # activity list
TTL_RIDE = 86400    # a single ride's detail is immutable once recorded

# --- Storage ----------------------------------------------------------------
USERS_FILE = "bosch_users.json"        # multi-user token store
LEGACY_TOKEN_FILE = "bosch_tokens.json"  # imported on first run if present
WEBHOOKS_FILE = "bosch_webhooks.json"  # outbound webhook subscriptions
POLLER_STATE_FILE = "bosch_poller_state.json"  # last-known snapshot per bike
EVENTS_LOG_FILE = "bosch_events.jsonl"  # append-only event log

# --- Event poller -----------------------------------------------------------
POLL_INTERVAL = 300     # seconds between poll cycles
BATTERY_LOW_PCT = 20    # threshold for the battery.low event
BATTERY_FULL_PCT = 100  # level considered "full"
EVENTS_LOG_MAX = 500    # recent events kept for GET /api/events
WEBHOOK_TIMEOUT = 10
WEBHOOK_RETRIES = 3

# --- Local desktop notifications (macOS) ------------------------------------
# Off by default now: the "Bosch Flow" menu bar app posts native notifications
# by reading /api/events. Set True to also fire terminal-notifier from the server.
NOTIFY_ENABLED = False
# Attribute notifications to a real app so they render fully native. Point this
# at a dedicated "Bosch Flow" app bundle id once one exists; Terminal until then.
NOTIFY_SENDER = "com.apple.Terminal"
