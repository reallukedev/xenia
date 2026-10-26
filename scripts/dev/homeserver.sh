#!/bin/zsh
# Starts the local test homeserver (Synapse on http://localhost:8008) if it isn't running. The
# first run installs Synapse with uv (or python3's venv and pip) and writes a config for local
# testing: open registration, no rate limits, sliding sync. Synapse and its data live outside the
# repo, in ~/.cache/matrix-client/synapse (XENIA_SYNAPSE_DIR to put them elsewhere).
set -eu
ROOT="${XENIA_SYNAPSE_DIR:-$HOME/.cache/matrix-client/synapse}"
CONFIG="$ROOT/data/homeserver.yaml"
APPSERVICE="$ROOT/data/history-appservice.yaml"

# Installs Python packages into Synapse's environment.
venv_install() {
  if command -v uv >/dev/null; then
    uv pip install --quiet --python "$ROOT/.venv/bin/python" "$@"
  else
    "$ROOT/.venv/bin/python" -m pip install --quiet "$@"
  fi
}

if [ ! -f "$CONFIG" ]; then
  echo "Installing Synapse in $ROOT (first run only)"
  mkdir -p "$ROOT/data"
  if command -v uv >/dev/null; then
    uv venv --quiet --python 3.12 "$ROOT/.venv"
  else
    python3 -m venv "$ROOT/.venv"
  fi
  venv_install "matrix-synapse[url-preview]"
  (cd "$ROOT/data" && "$ROOT/.venv/bin/python" -m synapse.app.homeserver \
    --server-name localhost --config-path homeserver.yaml --generate-config --report-stats=no >/dev/null)
  cat >> "$CONFIG" <<YAML

# Added by scripts/dev/homeserver.sh: a server for local testing only.
enable_registration: true
enable_registration_without_verification: true
federation_domain_whitelist: []
suppress_key_server_warning: true
max_upload_size: 100M
user_directory:
  enabled: true
  search_all_users: true
room_list_publication_rules:
  - action: allow
experimental_features:
  msc3266_enabled: true
  msc4186_enabled: true
rc_message: { per_second: 1000, burst_count: 1000 }
rc_registration: { per_second: 1000, burst_count: 1000 }
rc_login:
  address: { per_second: 1000, burst_count: 1000 }
  account: { per_second: 1000, burst_count: 1000 }
  failed_attempts: { per_second: 1000, burst_count: 1000 }
rc_joins:
  local: { per_second: 1000, burst_count: 1000 }
  remote: { per_second: 1000, burst_count: 1000 }
rc_invites:
  per_room: { per_second: 1000, burst_count: 1000 }
  per_user: { per_second: 1000, burst_count: 1000 }
  per_issuer: { per_second: 1000, burst_count: 1000 }
rc_room_creation: { per_second: 1000, burst_count: 1000 }
ip_range_whitelist:
  - 127.0.0.1
  - "::1"
app_service_config_files:
  - $APPSERVICE
url_preview_enabled: true
url_preview_ip_range_blacklist:
  - 127.0.0.0/8
  - 10.0.0.0/8
  - 172.16.0.0/12
  - 192.168.0.0/16
  - 100.64.0.0/10
  - 169.254.0.0/16
  - "::1/128"
  - "fe80::/10"
  - "fc00::/7"
YAML
fi

# Servers set up before a setting below existed get it added (and restart to load it).
# Let the server push to scripts/dev/push-gateway.mjs on this machine. Synapse refuses private
# addresses for outgoing requests unless they're allowed here.
if [ -f "$CONFIG" ] && ! grep -q '^ip_range_whitelist:' "$CONFIG"; then
  printf '\n# Added by scripts/dev/homeserver.sh: pushes to the local gateway.\nip_range_whitelist:\n  - 127.0.0.1\n  - "::1"\n' >> "$CONFIG"
  if curl -sf -m 2 http://localhost:8008/_matrix/client/versions >/dev/null; then
    echo "Restarting the homeserver to allow local pushes"
    pkill -f "synapse.app.homeserver -c homeserver.yaml" || true
    sleep 2
  fi
fi
# A local application service, so scripts/dev/seed-long-history.mjs can backdate messages (only
# application services may set an event's timestamp). It receives nothing: it has no URL.
if [ -f "$CONFIG" ] && [ ! -f "$APPSERVICE" ]; then
  cat > "$APPSERVICE" <<'YAML'
id: relay-history
url: null
as_token: relay-dev-history-as-token
hs_token: relay-dev-history-hs-token
sender_localpart: history
rate_limited: false
namespaces:
  users:
    - exclusive: true
      regex: "@history_.*:localhost"
  aliases: []
  rooms: []
YAML
fi
if [ -f "$CONFIG" ] && ! grep -q '^app_service_config_files:' "$CONFIG"; then
  printf '\n# Added by scripts/dev/homeserver.sh: backdated history for seed-long-history.mjs.\napp_service_config_files:\n  - %s\n' "$APPSERVICE" >> "$CONFIG"
  if curl -sf -m 2 http://localhost:8008/_matrix/client/versions >/dev/null; then
    echo "Restarting the homeserver to load the history app service"
    pkill -f "synapse.app.homeserver -c homeserver.yaml" || true
    sleep 2
  fi
fi
# Link previews, made by the server so the apps never contact the sites themselves. Private
# addresses stay off limits.
if [ -f "$CONFIG" ] && grep -q '^url_preview_enabled: false' "$CONFIG"; then
  sed -i '' 's/^url_preview_enabled: false/url_preview_enabled: true/' "$CONFIG"
  printf '\n# Added by scripts/dev/homeserver.sh: link previews.\nurl_preview_ip_range_blacklist:\n  - 127.0.0.0/8\n  - 10.0.0.0/8\n  - 172.16.0.0/12\n  - 192.168.0.0/16\n  - 100.64.0.0/10\n  - 169.254.0.0/16\n  - "::1/128"\n  - "fe80::/10"\n  - "fc00::/7"\n' >> "$CONFIG"
  if curl -sf -m 2 http://localhost:8008/_matrix/client/versions >/dev/null; then
    echo "Restarting the homeserver to turn on link previews"
    pkill -f "synapse.app.homeserver -c homeserver.yaml" || true
    sleep 2
  fi
fi
# Synapse reads pages for previews with lxml, which its plain install leaves out.
if [ -f "$CONFIG" ] && grep -q '^url_preview_enabled: true' "$CONFIG" && ! "$ROOT/.venv/bin/python" -c 'import lxml' 2>/dev/null; then
  venv_install lxml
fi
if curl -sf -m 2 http://localhost:8008/_matrix/client/versions >/dev/null; then
  echo "Homeserver already running on http://localhost:8008"
  exit 0
fi
cd "$ROOT/data"
nohup "$ROOT/.venv/bin/python" -m synapse.app.homeserver -c homeserver.yaml > run.log 2>&1 &
for _ in {1..30}; do
  curl -sf -m 2 http://localhost:8008/_matrix/client/versions >/dev/null && { echo "Homeserver running on http://localhost:8008"; exit 0; }
  sleep 1
done
echo "Homeserver didn't start. See $ROOT/data/run.log" >&2
exit 1
