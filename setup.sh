#!/bin/bash
set -Eeuo pipefail

cleanup() {
  rm -f temp_mas_config.yaml
}

on_err() {
  local line="$1"
  echo "[!] setup failed at line ${line}"
  exit 1
}

trap cleanup EXIT
trap 'on_err $LINENO' ERR

echo "====================================================================="
echo " Secure Matrix + MAS + LiveKit + Ketesa Admin Setup (Single Domain)  "
echo "====================================================================="

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[!] Required command not found: $1"
    exit 1
  }
}

require_cmd awk
require_cmd sed
require_cmd grep

MARKER_FILE=".setup-complete"
EXISTING_DOMAIN=""
REGENERATE_NGINX_ONLY=0

if [[ "${1:-}" == "--regenerate-nginx" ]]; then
  REGENERATE_NGINX_ONLY=1
fi

if (( REGENERATE_NGINX_ONLY == 0 )); then
  require_cmd docker
  require_cmd openssl
  require_cmd ip
  require_cmd python3

  docker compose version >/dev/null 2>&1 || {
    echo "[!] docker compose plugin is required."
    exit 1
  }
fi

if [[ -f "${MARKER_FILE}" ]]; then
  EXISTING_DOMAIN="$(awk -F= '/^domain=/{print $2}' "${MARKER_FILE}" 2>/dev/null || true)"
  if (( REGENERATE_NGINX_ONLY == 0 )); then
    echo "[*] Setup was already completed${EXISTING_DOMAIN:+ for ${EXISTING_DOMAIN}}."
    echo "[*] Nothing was changed."
    echo "[*] To regenerate only nginx call/admin config files, run: ./setup.sh --regenerate-nginx"
    docker compose ps 2>/dev/null || true
    exit 0
  fi

  echo "[*] Existing setup detected${EXISTING_DOMAIN:+ for ${EXISTING_DOMAIN}}."
  echo "[*] Regenerating nginx config files only (--regenerate-nginx mode)."
fi

if (( REGENERATE_NGINX_ONLY == 0 )) && [[ -e .env || -e docker-compose.yml || -d data || -d scripts ]]; then
  echo "[!] Existing setup files or directories were found, but no completion marker exists."
  echo "    Refusing to overwrite a partial or previous installation."
  echo "    For a clean rebuild run:"
  echo "    docker compose down -v --remove-orphans 2>/dev/null || true"
  echo "    rm -rf data scripts docker-compose.yml .env .setup-complete temp_mas_config.yaml"
  exit 1
fi

if (( REGENERATE_NGINX_ONLY == 0 )); then
  DETECTED_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || true)"

  read -rp "Enter Server Public IP [${DETECTED_IP}]: " SERVER_IP
  SERVER_IP="${SERVER_IP:-$DETECTED_IP}"
else
  SERVER_IP=""
fi

if [[ -n "${EXISTING_DOMAIN}" ]]; then
  read -rp "Enter Matrix Domain [${EXISTING_DOMAIN}]: " MATRIX_DOMAIN
  MATRIX_DOMAIN="${MATRIX_DOMAIN:-$EXISTING_DOMAIN}"
else
  read -rp "Enter Matrix Domain (e.g. matrix.example.com): " MATRIX_DOMAIN
fi
MATRIX_DOMAIN="$(echo "${MATRIX_DOMAIN}" | tr -d '\r\n[:space:]')"

CURRENT_ADMIN_ALLOWLIST="$(awk '/^allow[[:space:]]+/{gsub(";","",$2); entries=(entries ? entries "," $2 : $2)} END{print entries}' conf.d/snippets/admin-allowlist.inc 2>/dev/null || true)"
if [[ -n "${CURRENT_ADMIN_ALLOWLIST}" ]]; then
  read -rp "Enter allowed admin IPs/CIDRs [${CURRENT_ADMIN_ALLOWLIST}]: " ADMIN_ALLOWLIST_RAW
  ADMIN_ALLOWLIST_RAW="${ADMIN_ALLOWLIST_RAW:-$CURRENT_ADMIN_ALLOWLIST}"
else
  read -rp "Enter allowed admin IPs/CIDRs (comma-separated, e.g. 203.0.113.10,198.51.100.20): " ADMIN_ALLOWLIST_RAW
fi
ADMIN_ALLOWLIST_RAW="$(echo "${ADMIN_ALLOWLIST_RAW}" | tr -d '\r\n')"
# Accept English/Persian/Arabic separators.
ADMIN_ALLOWLIST_NORMALIZED="${ADMIN_ALLOWLIST_RAW//$'\u060C'/,}"
ADMIN_ALLOWLIST_NORMALIZED="${ADMIN_ALLOWLIST_NORMALIZED//$'\u066C'/,}"
ADMIN_ALLOWLIST_NORMALIZED="${ADMIN_ALLOWLIST_NORMALIZED//$'\u061B'/,}"
ADMIN_ALLOWLIST_NORMALIZED="$(echo "${ADMIN_ALLOWLIST_NORMALIZED}" | tr ';' ',')"

is_valid_ipv4_or_cidr() {
  local value="$1"
  local ip="${value%%/*}"
  local mask=""
  local o1 o2 o3 o4

  if [[ "${value}" == */* ]]; then
    mask="${value##*/}"
    if [[ ! "${mask}" =~ ^[0-9]{1,2}$ ]]; then
      return 1
    fi
    if (( 10#${mask} < 0 || 10#${mask} > 32 )); then
      return 1
    fi
  fi

  if [[ ! "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    return 1
  fi

  IFS='.' read -r o1 o2 o3 o4 <<< "${ip}"
  for octet in "${o1}" "${o2}" "${o3}" "${o4}"; do
    if (( 10#${octet} < 0 || 10#${octet} > 255 )); then
      return 1
    fi
  done

  return 0
}

if (( REGENERATE_NGINX_ONLY == 0 )) && [[ -z "${SERVER_IP}" ]]; then
  echo "[!] SERVER_IP is required."
  exit 1
fi

if [[ -z "${MATRIX_DOMAIN}" || -z "${ADMIN_ALLOWLIST_RAW}" ]]; then
  echo "[!] MATRIX_DOMAIN and admin allowlist are required."
  exit 1
fi

if [[ ! "${MATRIX_DOMAIN}" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo "[!] MATRIX_DOMAIN looks invalid."
  exit 1
fi

declare -a ADMIN_ALLOWLIST_ENTRIES=()
token=""
while IFS= read -r token || [[ -n "${token}" ]]; do
  # Remove spaces and any invisible/non-IP punctuation characters.
  token="$(echo "${token}" | tr -d '[:space:]' | sed 's/[^0-9.\/]//g')"
  [[ -z "${token}" ]] && continue

  if ! is_valid_ipv4_or_cidr "${token}"; then
    echo "[!] Invalid admin IP/CIDR entry: ${token}"
    echo "    Example: 203.0.113.10,198.51.100.20"
    exit 1
  fi

  ADMIN_ALLOWLIST_ENTRIES+=("${token}")
done < <(printf '%s\n' "${ADMIN_ALLOWLIST_NORMALIZED}" | tr ',' '\n')

if (( ${#ADMIN_ALLOWLIST_ENTRIES[@]} == 0 )); then
  echo "[!] No valid admin IP/CIDR entries were provided."
  exit 1
fi

if (( REGENERATE_NGINX_ONLY == 0 )); then
  gen_pass() {
    openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | head -c 32
  }

  PG_SUPER_USER="postgres"
  PG_SUPER_PASSWORD="$(gen_pass)"
  PG_APP_USER="matrix"
  PG_APP_PASSWORD="$(gen_pass)"

  SYNAPSE_REGISTRATION_SECRET="$(gen_pass)"
  SYNAPSE_MACAROON_SECRET="$(gen_pass)"
  SYNAPSE_FORM_SECRET="$(gen_pass)"
  MAS_MATRIX_SECRET="$(gen_pass)"

  LK_API_KEY="API$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 16)"
  LK_SECRET="$(gen_pass)"
fi

LIVEKIT_URL_PATH="/livekit/sfu"
LIVEKIT_JWT_BASE_PATH="/livekit/jwt"

LIVEKIT_RTC_UDP_PORT="7882"
LIVEKIT_TCP_PORT="7881"
LIVEKIT_USE_EXTERNAL_IP="false"
LIVEKIT_ENABLE_LOOPBACK_CANDIDATE="false"
LIVEKIT_ALLOW_TCP_FALLBACK="true"
LIVEKIT_TURN_ENABLED="true"
LIVEKIT_TURN_DOMAIN="${MATRIX_DOMAIN}"
LIVEKIT_TURN_UDP_PORT="3478"
LIVEKIT_TURN_TLS_PORT="5349"
LIVEKIT_TURN_RELAY_RANGE_START="52000"
LIVEKIT_TURN_RELAY_RANGE_END="52049"
LIVEKIT_TURN_EXTERNAL_TLS="false"
LIVEKIT_TLS_CERT_DIR="${HOME}/nginx-proxy/certs"
LIVEKIT_TURN_CERT_FILE="/etc/lk-certs/live/${MATRIX_DOMAIN}/fullchain.pem"
LIVEKIT_TURN_KEY_FILE="/etc/lk-certs/live/${MATRIX_DOMAIN}/privkey.pem"
LIVEKIT_LOG_JSON="false"
LIVEKIT_LOG_LEVEL="info"

SYNAPSE_IMAGE="ghcr.io/element-hq/synapse:v1.150.0"
MAS_IMAGE="ghcr.io/element-hq/matrix-authentication-service:1"
LIVEKIT_IMAGE="livekit/livekit-server:v1.10.1"
LIVEKIT_JWT_IMAGE="ghcr.io/element-hq/lk-jwt-service:0.4.4"
ELEMENT_WEB_IMAGE="ghcr.io/element-hq/element-web:v1.12.6"
KETESA_IMAGE="ghcr.io/etkecc/ketesa:v1.2.0-subpath-admin"
POSTGRES_IMAGE="postgres:15"
REDIS_IMAGE="redis:7"
RESTART_POLICY="unless-stopped"
POSTGRES_DATA_PATH="./data/postgres"
SYNAPSE_DATA_PATH="./data/synapse"
MAS_DATA_PATH="./data/mas"
LIVEKIT_DATA_PATH="./data/livekit"
KETESA_CONFIG_PATH="./data/ketesa/config.json"
ELEMENT_WEB_CONFIG_PATH="./data/element-web/config.json"
POSTGRES_INIT_SQL_PATH="./scripts/01-init.sql"

DB_HOST="elementx-postgres"
REDIS_HOST="elementx-redis"
SYNAPSE_HOST="elementx-synapse"
MAS_HOST="elementx-mas"
LIVEKIT_HOST="elementx-livekit"
LIVEKIT_JWT_HOST="elementx-livekit-jwt"
ELEMENT_WEB_HOST="elementx-element-web"
KETESA_HOST="elementx-ketesa"
NGINX_DEFAULT_CONF_LOCAL_PATH="conf.d/default.conf"
NGINX_DEFAULT_CONF_TARGET_PATH="~/nginx-proxy/conf.d/default.conf"
ADMIN_ALLOWLIST_LOCAL_PATH="conf.d/snippets/admin-allowlist.inc"
ADMIN_ALLOWLIST_TARGET_PATH="~/nginx-proxy/conf.d/snippets/admin-allowlist.inc"

if (( REGENERATE_NGINX_ONLY == 0 )); then
  mkdir -p data/postgres data/synapse data/mas data/livekit data/ketesa data/element-web scripts conf.d conf.d/snippets
  chmod 755 data data/postgres data/synapse data/mas data/livekit data/ketesa data/element-web scripts conf.d conf.d/snippets

  if [[ ! -f "${LIVEKIT_TLS_CERT_DIR}/live/${MATRIX_DOMAIN}/fullchain.pem" || ! -f "${LIVEKIT_TLS_CERT_DIR}/live/${MATRIX_DOMAIN}/privkey.pem" ]]; then
    echo "[!] LiveKit TURN TLS certificate files not found."
    echo "    Expected: ${LIVEKIT_TLS_CERT_DIR}/live/${MATRIX_DOMAIN}/fullchain.pem and ${LIVEKIT_TLS_CERT_DIR}/live/${MATRIX_DOMAIN}/privkey.pem"
    echo "    Make sure nginx-proxy certificates exist before running full setup."
    exit 1
  fi
else
  mkdir -p conf.d conf.d/snippets
  chmod 755 conf.d conf.d/snippets
fi

echo "[*] Writing nginx admin IP allowlist..."
{
  for ip in "${ADMIN_ALLOWLIST_ENTRIES[@]}"; do
    echo "allow ${ip};"
  done
  echo "deny all;"
} > "${ADMIN_ALLOWLIST_LOCAL_PATH}"

ALLOW_LINES_WRITTEN="$(grep -c '^allow ' "${ADMIN_ALLOWLIST_LOCAL_PATH}" || true)"
if (( ALLOW_LINES_WRITTEN != ${#ADMIN_ALLOWLIST_ENTRIES[@]} )); then
  echo "[!] Failed to write all admin allowlist IP entries."
  exit 1
fi

echo "[*] Parsed ${#ADMIN_ALLOWLIST_ENTRIES[@]} admin allowlist entries."
chmod 644 "${ADMIN_ALLOWLIST_LOCAL_PATH}"

echo "[*] Writing nginx default config..."
cat > "${NGINX_DEFAULT_CONF_LOCAL_PATH}" <<EOF
upstream synapse_up     { server ${SYNAPSE_HOST}:8008;     keepalive 32; }
upstream mas_up         { server ${MAS_HOST}:8080;         keepalive 32; }
upstream livekit_up     { server ${LIVEKIT_HOST}:7880;     keepalive 32; }
upstream livekit_jwt_up { server ${LIVEKIT_JWT_HOST}:8080; keepalive 32; }
upstream element_web_up { server ${ELEMENT_WEB_HOST}:80;   keepalive 16; }
upstream mas_admin_up   { server ${MAS_HOST}:8081;         keepalive 16; }
upstream ketesa_up      { server ${KETESA_HOST}:8080;      keepalive 16; }


# ----------------------------
# MATRIX, MAS, KETESA & LIVEKIT
# ----------------------------
server {
  server_name ${MATRIX_DOMAIN};
  listen 443 ssl;
  listen [::]:443 ssl;
  http2 on;

  ssl_certificate     /etc/letsencrypt/live/${MATRIX_DOMAIN}/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/${MATRIX_DOMAIN}/privkey.pem;
  include /etc/letsencrypt/conf/options-ssl-nginx.conf;
  ssl_dhparam /etc/letsencrypt/conf/ssl-dhparams.pem;

  client_max_body_size 50M;

  add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
  add_header X-Content-Type-Options "nosniff" always;
  add_header X-Frame-Options "SAMEORIGIN" always;
  add_header Referrer-Policy "strict-origin-when-cross-origin" always;

  # --------------------------------------------------
  # Well-known
  # --------------------------------------------------
  location = /.well-known/matrix/client {
    default_type application/json;
    add_header Access-Control-Allow-Origin * always;
    add_header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS" always;
    add_header Access-Control-Allow-Headers "X-Requested-With, Content-Type, Authorization" always;
    add_header Cache-Control "no-store, max-age=0" always;
    return 200 '{"m.homeserver":{"base_url":"https://${MATRIX_DOMAIN}"},"org.matrix.msc2965.authentication":{"issuer":"https://${MATRIX_DOMAIN}/","account":"https://${MATRIX_DOMAIN}/account"},"org.matrix.msc4143.rtc_foci":[{"type":"livekit","livekit_service_url":"https://${MATRIX_DOMAIN}${LIVEKIT_JWT_BASE_PATH}"}],"cc.etke.ketesa":{"restrictBaseUrl":"https://${MATRIX_DOMAIN}"}}';
  }

  location = /.well-known/openid-configuration {
    proxy_pass http://mas_up;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }

  # Explicit delegation for server-server lookups on port 443.
  location = /.well-known/matrix/server {
    default_type application/json;
    add_header Cache-Control "no-store, max-age=0" always;
    return 200 '{"m.server":"${MATRIX_DOMAIN}:443"}';
  }

  # Public MatrixRTC transport discovery. Exact locations keep these endpoints
  # out of Synapse auth handling for Element X clients that probe anonymously.
  location = /_matrix/client/unstable/org.matrix.msc4143/rtc/transports {
    default_type application/json;
    add_header Access-Control-Allow-Origin * always;
    add_header Access-Control-Allow-Methods "GET, OPTIONS" always;
    add_header Access-Control-Allow-Headers "X-Requested-With, Content-Type, Authorization" always;
    add_header Cache-Control "no-store, max-age=0" always;
    return 200 '{"rtc_transports":[{"type":"livekit","livekit_service_url":"https://${MATRIX_DOMAIN}${LIVEKIT_JWT_BASE_PATH}"}]}';
  }

  location = /_matrix/client/v1/rtc/transports {
    default_type application/json;
    add_header Access-Control-Allow-Origin * always;
    add_header Access-Control-Allow-Methods "GET, OPTIONS" always;
    add_header Access-Control-Allow-Headers "X-Requested-With, Content-Type, Authorization" always;
    add_header Cache-Control "no-store, max-age=0" always;
    return 200 '{"rtc_transports":[{"type":"livekit","livekit_service_url":"https://${MATRIX_DOMAIN}${LIVEKIT_JWT_BASE_PATH}"}]}';
  }

  # --------------------------------------------------
  # Admin UI hardening
  # --------------------------------------------------
  location = /admin {
    return 302 https://\$host/admin/?server=https%3A%2F%2F${MATRIX_DOMAIN};
  }

  location = /admin/ {
    if (\$arg_server = "") {
      return 302 https://\$host/admin/?server=https%3A%2F%2F${MATRIX_DOMAIN};
    }

    satisfy all;
    include /etc/nginx/conf.d/snippets/admin-allowlist.inc;

    proxy_pass http://ketesa_up;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }

  location /admin/ {
    satisfy all;
    include /etc/nginx/conf.d/snippets/admin-allowlist.inc;

    proxy_pass http://ketesa_up;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }

  location ^~ /_synapse/admin/ {
    satisfy all;
    include /etc/nginx/conf.d/snippets/admin-allowlist.inc;

    proxy_pass http://synapse_up;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    client_max_body_size 50M;
  }

  location ^~ /api/admin/ {
    satisfy all;
    include /etc/nginx/conf.d/snippets/admin-allowlist.inc;

    proxy_pass http://mas_admin_up;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }

  # --------------------------------------------------
  # LiveKit
  # --------------------------------------------------
  location = ${LIVEKIT_JWT_BASE_PATH} {
    return 308 https://\$host${LIVEKIT_JWT_BASE_PATH}/;
  }

  location ^~ ${LIVEKIT_JWT_BASE_PATH}/ {
    proxy_pass http://livekit_jwt_up/;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }

  # Standard MatrixRTC SFU endpoint.
  location = ${LIVEKIT_URL_PATH} {
    proxy_pass http://livekit_up/;

    proxy_http_version 1.1;
    proxy_send_timeout 3600s;
    proxy_read_timeout 3600s;
    proxy_buffering off;

    proxy_set_header Accept-Encoding gzip;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";

    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }

  location ^~ ${LIVEKIT_URL_PATH}/ {
    proxy_pass http://livekit_up/;

    proxy_http_version 1.1;
    proxy_send_timeout 3600s;
    proxy_read_timeout 3600s;
    proxy_buffering off;

    proxy_set_header Accept-Encoding gzip;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";

    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }

  # Legacy path kept for backward compatibility.
  location = /sfu/get {
    proxy_pass http://livekit_jwt_up;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }

  # Compatibility route for clients still connecting to /call.
  location = /call {
    proxy_pass http://livekit_up/;

    proxy_http_version 1.1;
    proxy_send_timeout 3600s;
    proxy_read_timeout 3600s;
    proxy_buffering off;

    proxy_set_header Accept-Encoding gzip;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";

    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }

  location /call/ {
    proxy_pass http://livekit_up/;

    proxy_http_version 1.1;
    proxy_send_timeout 3600s;
    proxy_read_timeout 3600s;
    proxy_buffering off;

    proxy_set_header Accept-Encoding gzip;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";

    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }

  # --------------------------------------------------
  # Element Web
  # --------------------------------------------------
  location = /web {
    return 301 https://\$host/web/;
  }

  location ^~ /web/ {
    proxy_pass http://element_web_up/;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-Prefix /web;
  }

  # --------------------------------------------------
  # MAS compatibility layer
  # --------------------------------------------------
  location ~ ^/_matrix/client/[^/]+/(login|logout|refresh)$ {
    proxy_pass http://mas_up;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }

  location ~ ^/(oauth2|login|register|account|graphql|assets|verify|reauth)(/|$) {
    proxy_pass http://mas_up;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }

  # --------------------------------------------------
  # Synapse client APIs
  # --------------------------------------------------
  location ~ ^(/_matrix|/_synapse/client|/_synapse/mas|/_synapse/federation) {
    proxy_pass http://synapse_up;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    client_max_body_size 50M;
  }

  # --------------------------------------------------
  # default root -> MAS
  # --------------------------------------------------
  location / {
    proxy_pass http://mas_up;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }
}
EOF
chmod 644 "${NGINX_DEFAULT_CONF_LOCAL_PATH}"

if (( REGENERATE_NGINX_ONLY == 1 )); then
  echo "[*] Nginx regeneration complete. Service data, secrets, databases, and compose files were not changed."
  echo "[*] Copy updated files, then reload nginx:"
  echo "    cp ./${NGINX_DEFAULT_CONF_LOCAL_PATH} ${NGINX_DEFAULT_CONF_TARGET_PATH}"
  echo "    cp ./${ADMIN_ALLOWLIST_LOCAL_PATH} ${ADMIN_ALLOWLIST_TARGET_PATH}"
  echo "    docker exec nginx-proxy nginx -t"
  echo "    docker exec nginx-proxy nginx -s reload"
  exit 0
fi

echo "[*] Ensuring external nginx network exists..."
docker network inspect nginx >/dev/null 2>&1 || docker network create nginx >/dev/null

echo "[*] Writing .env..."
cat > .env <<EOF
SERVER_IP=${SERVER_IP}
MATRIX_DOMAIN=${MATRIX_DOMAIN}

PG_SUPER_USER=${PG_SUPER_USER}
PG_SUPER_PASSWORD=${PG_SUPER_PASSWORD}
PG_APP_USER=${PG_APP_USER}
PG_APP_PASSWORD=${PG_APP_PASSWORD}

SYNAPSE_REGISTRATION_SECRET=${SYNAPSE_REGISTRATION_SECRET}
SYNAPSE_MACAROON_SECRET=${SYNAPSE_MACAROON_SECRET}
SYNAPSE_FORM_SECRET=${SYNAPSE_FORM_SECRET}
MAS_MATRIX_SECRET=${MAS_MATRIX_SECRET}

LIVEKIT_API_KEY=${LK_API_KEY}
LIVEKIT_SECRET_KEY=${LK_SECRET}
LIVEKIT_URL=wss://${MATRIX_DOMAIN}${LIVEKIT_URL_PATH}
LIVEKIT_JWT_BASE_URL=https://${MATRIX_DOMAIN}${LIVEKIT_JWT_BASE_PATH}
LIVEKIT_RTC_UDP_PORT=${LIVEKIT_RTC_UDP_PORT}
LIVEKIT_TCP_PORT=${LIVEKIT_TCP_PORT}
LIVEKIT_USE_EXTERNAL_IP=${LIVEKIT_USE_EXTERNAL_IP}
LIVEKIT_ENABLE_LOOPBACK_CANDIDATE=${LIVEKIT_ENABLE_LOOPBACK_CANDIDATE}
LIVEKIT_ALLOW_TCP_FALLBACK=${LIVEKIT_ALLOW_TCP_FALLBACK}
LIVEKIT_TURN_ENABLED=${LIVEKIT_TURN_ENABLED}
LIVEKIT_TURN_DOMAIN=${LIVEKIT_TURN_DOMAIN}
LIVEKIT_TURN_UDP_PORT=${LIVEKIT_TURN_UDP_PORT}
LIVEKIT_TURN_TLS_PORT=${LIVEKIT_TURN_TLS_PORT}
LIVEKIT_TURN_RELAY_RANGE_START=${LIVEKIT_TURN_RELAY_RANGE_START}
LIVEKIT_TURN_RELAY_RANGE_END=${LIVEKIT_TURN_RELAY_RANGE_END}
LIVEKIT_TURN_EXTERNAL_TLS=${LIVEKIT_TURN_EXTERNAL_TLS}
LIVEKIT_TLS_CERT_DIR=${LIVEKIT_TLS_CERT_DIR}
LIVEKIT_TURN_CERT_FILE=${LIVEKIT_TURN_CERT_FILE}
LIVEKIT_TURN_KEY_FILE=${LIVEKIT_TURN_KEY_FILE}
LIVEKIT_LOG_JSON=${LIVEKIT_LOG_JSON}
LIVEKIT_LOG_LEVEL=${LIVEKIT_LOG_LEVEL}
SYNAPSE_IMAGE=${SYNAPSE_IMAGE}
MAS_IMAGE=${MAS_IMAGE}
LIVEKIT_IMAGE=${LIVEKIT_IMAGE}
LIVEKIT_JWT_IMAGE=${LIVEKIT_JWT_IMAGE}
ELEMENT_WEB_IMAGE=${ELEMENT_WEB_IMAGE}
KETESA_IMAGE=${KETESA_IMAGE}
POSTGRES_IMAGE=${POSTGRES_IMAGE}
REDIS_IMAGE=${REDIS_IMAGE}
RESTART_POLICY=${RESTART_POLICY}

POSTGRES_DATA_PATH=${POSTGRES_DATA_PATH}
SYNAPSE_DATA_PATH=${SYNAPSE_DATA_PATH}
MAS_DATA_PATH=${MAS_DATA_PATH}
LIVEKIT_DATA_PATH=${LIVEKIT_DATA_PATH}
KETESA_CONFIG_PATH=${KETESA_CONFIG_PATH}
ELEMENT_WEB_CONFIG_PATH=${ELEMENT_WEB_CONFIG_PATH}
POSTGRES_INIT_SQL_PATH=${POSTGRES_INIT_SQL_PATH}

DB_HOST=${DB_HOST}
REDIS_HOST=${REDIS_HOST}
SYNAPSE_HOST=${SYNAPSE_HOST}
MAS_HOST=${MAS_HOST}
LIVEKIT_HOST=${LIVEKIT_HOST}
LIVEKIT_JWT_HOST=${LIVEKIT_JWT_HOST}
ELEMENT_WEB_HOST=${ELEMENT_WEB_HOST}
KETESA_HOST=${KETESA_HOST}
EOF
chmod 600 .env

echo "[*] Writing Postgres init script..."
cat > scripts/01-init.sql <<EOF
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${PG_APP_USER}') THEN
    CREATE ROLE ${PG_APP_USER} WITH LOGIN PASSWORD '${PG_APP_PASSWORD}';
  ELSE
    ALTER ROLE ${PG_APP_USER} WITH LOGIN PASSWORD '${PG_APP_PASSWORD}';
  END IF;
END
\$\$;

SELECT format(
  'CREATE DATABASE %I WITH OWNER %I TEMPLATE template0 ENCODING %L LC_COLLATE %L LC_CTYPE %L',
  'synapse', '${PG_APP_USER}', 'UTF8', 'C', 'C'
)
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'synapse')\gexec

SELECT format(
  'CREATE DATABASE %I WITH OWNER %I TEMPLATE template0 ENCODING %L LC_COLLATE %L LC_CTYPE %L',
  'mas', '${PG_APP_USER}', 'UTF8', 'C', 'C'
)
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'mas')\gexec
EOF
chmod 644 scripts/01-init.sql

echo "[*] Writing docker-compose.yml..."
cat > docker-compose.yml <<EOF
services:
  postgres:
    image: \${POSTGRES_IMAGE}
    container_name: \${DB_HOST}
    hostname: \${DB_HOST}
    restart: \${RESTART_POLICY}
    environment:
      POSTGRES_USER: "\${PG_SUPER_USER}"
      POSTGRES_PASSWORD: "\${PG_SUPER_PASSWORD}"
      POSTGRES_DB: "postgres"
      POSTGRES_INITDB_ARGS: "--encoding=UTF8 --locale=C"
      PGDATA: "/var/lib/postgresql/data/pgdata"
    volumes:
      - \${POSTGRES_DATA_PATH}:/var/lib/postgresql/data
      - \${POSTGRES_INIT_SQL_PATH}:/docker-entrypoint-initdb.d/01-init.sql:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \${PG_SUPER_USER} -d postgres -h 127.0.0.1"]
      interval: 5s
      timeout: 5s
      retries: 30
      start_period: 20s
    networks:
      matrix-internal:
        aliases:
          - \${DB_HOST}

  redis:
    image: \${REDIS_IMAGE}
    container_name: \${REDIS_HOST}
    hostname: \${REDIS_HOST}
    restart: \${RESTART_POLICY}
    networks:
      matrix-internal:
        aliases:
          - \${REDIS_HOST}

  synapse:
    image: \${SYNAPSE_IMAGE}
    container_name: \${SYNAPSE_HOST}
    hostname: \${SYNAPSE_HOST}
    restart: \${RESTART_POLICY}
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_started
    environment:
      SYNAPSE_CONFIG_DIR: "/data"
      SYNAPSE_CONFIG_PATH: "/data/homeserver.yaml"
    volumes:
      - \${SYNAPSE_DATA_PATH}:/data
    networks:
      matrix-internal:
        aliases:
          - \${SYNAPSE_HOST}
      nginx:
        aliases:
          - \${SYNAPSE_HOST}

  mas:
    image: \${MAS_IMAGE}
    container_name: \${MAS_HOST}
    hostname: \${MAS_HOST}
    restart: \${RESTART_POLICY}
    depends_on:
      postgres:
        condition: service_healthy
      synapse:
        condition: service_started
    command: ["server", "--config=/data/config.yaml"]
    volumes:
      - \${MAS_DATA_PATH}:/data
    networks:
      matrix-internal:
        aliases:
          - \${MAS_HOST}
      nginx:
        aliases:
          - \${MAS_HOST}

  livekit:
    image: \${LIVEKIT_IMAGE}
    container_name: \${LIVEKIT_HOST}
    hostname: \${LIVEKIT_HOST}
    restart: \${RESTART_POLICY}
    depends_on:
      redis:
        condition: service_started
    command: ["--config", "/etc/livekit/config.yaml", "--node-ip", "\${SERVER_IP}"]
    volumes:
      - \${LIVEKIT_DATA_PATH}:/etc/livekit:ro
      - \${LIVEKIT_TLS_CERT_DIR}:/etc/lk-certs:ro
    ports:
      - "\${LIVEKIT_TCP_PORT}:\${LIVEKIT_TCP_PORT}/tcp"
      - "\${LIVEKIT_RTC_UDP_PORT}:\${LIVEKIT_RTC_UDP_PORT}/udp"
      - "\${LIVEKIT_TURN_UDP_PORT}:\${LIVEKIT_TURN_UDP_PORT}/udp"
      - "\${LIVEKIT_TURN_TLS_PORT}:\${LIVEKIT_TURN_TLS_PORT}/tcp"
      - "\${LIVEKIT_TURN_RELAY_RANGE_START}-\${LIVEKIT_TURN_RELAY_RANGE_END}:\${LIVEKIT_TURN_RELAY_RANGE_START}-\${LIVEKIT_TURN_RELAY_RANGE_END}/udp"
    networks:
      matrix-internal:
        aliases:
          - \${LIVEKIT_HOST}
      nginx:
        aliases:
          - \${LIVEKIT_HOST}

  livekit-jwt:
    image: \${LIVEKIT_JWT_IMAGE}
    container_name: \${LIVEKIT_JWT_HOST}
    hostname: \${LIVEKIT_JWT_HOST}
    restart: \${RESTART_POLICY}
    depends_on:
      livekit:
        condition: service_started
    environment:
      LIVEKIT_JWT_BIND: ":8080"
      LIVEKIT_URL: "\${LIVEKIT_URL}"
      LIVEKIT_KEY: "\${LIVEKIT_API_KEY}"
      LIVEKIT_SECRET: "\${LIVEKIT_SECRET_KEY}"
      LIVEKIT_FULL_ACCESS_HOMESERVERS: "\${MATRIX_DOMAIN}"
    networks:
      matrix-internal:
        aliases:
          - \${LIVEKIT_JWT_HOST}
      nginx:
        aliases:
          - \${LIVEKIT_JWT_HOST}

  element-web:
    image: \${ELEMENT_WEB_IMAGE}
    container_name: \${ELEMENT_WEB_HOST}
    hostname: \${ELEMENT_WEB_HOST}
    restart: \${RESTART_POLICY}
    volumes:
      - \${ELEMENT_WEB_CONFIG_PATH}:/app/config.json:ro
    networks:
      nginx:
        aliases:
          - \${ELEMENT_WEB_HOST}

  ketesa:
    image: \${KETESA_IMAGE}
    container_name: \${KETESA_HOST}
    hostname: \${KETESA_HOST}
    restart: \${RESTART_POLICY}
    read_only: true
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    tmpfs:
      - /tmp:rw,noexec,nosuid,size=64m
    volumes:
      - \${KETESA_CONFIG_PATH}:/var/public/config.json:ro
    networks:
      nginx:
        aliases:
          - \${KETESA_HOST}

networks:
  matrix-internal:
    internal: true
  nginx:
    external: true
    name: nginx
EOF
chmod 644 docker-compose.yml

echo "[*] Generating Synapse base files..."
docker run --rm \
  -v "$(pwd)/data/synapse:/data" \
  -e SYNAPSE_SERVER_NAME="${MATRIX_DOMAIN}" \
  -e SYNAPSE_REPORT_STATS="no" \
  "${SYNAPSE_IMAGE}" generate >/dev/null

if [[ ! -f "data/synapse/${MATRIX_DOMAIN}.signing.key" ]]; then
  echo "[!] Synapse signing key was not generated."
  exit 1
fi

echo "[*] Writing Synapse config..."
cat > data/synapse/homeserver.yaml <<EOF
server_name: "${MATRIX_DOMAIN}"
pid_file: /data/homeserver.pid

listeners:
  - port: 8008
    tls: false
    type: http
    x_forwarded: true
    resources:
      - names: [client, federation, openid]
        compress: false

database:
  name: psycopg2
  args:
    user: "${PG_APP_USER}"
    password: "${PG_APP_PASSWORD}"
    database: "synapse"
    host: "${DB_HOST}"
    port: 5432
    cp_min: 5
    cp_max: 10

log_config: "/data/log.config"
media_store_path: /data/media_store
max_upload_size: 50M

registration_shared_secret: "${SYNAPSE_REGISTRATION_SECRET}"
report_stats: false
macaroon_secret_key: "${SYNAPSE_MACAROON_SECRET}"
form_secret: "${SYNAPSE_FORM_SECRET}"
signing_key_path: "/data/${MATRIX_DOMAIN}.signing.key"

public_baseurl: "https://${MATRIX_DOMAIN}/"
suppress_key_server_warning: true
trusted_key_servers: []

send_federation: false
allow_public_rooms_without_auth: false
allow_public_rooms_over_federation: false
url_preview_enabled: false
enable_registration: false

experimental_features:
  msc3266_enabled: true
  msc4222_enabled: true
  msc4143_enabled: true

# Required for stable MatrixRTC delayed events.
max_event_delay_duration: 24h

rc_message:
  per_second: 0.5
  burst_count: 30

rc_delayed_event_mgmt:
  per_second: 1
  burst_count: 20

matrix_rtc:
  transports:
    - type: livekit
      livekit_service_url: "https://${MATRIX_DOMAIN}/livekit/jwt"

matrix_authentication_service:
  enabled: true
  endpoint: "http://${MAS_HOST}:8080"
  secret: "${MAS_MATRIX_SECRET}"
EOF

echo "[*] Writing Synapse log config..."
cat > data/synapse/log.config <<'EOF'
version: 1

formatters:
  precise:
    format: '%(asctime)s - %(name)s - %(lineno)d - %(levelname)s - %(request)s - %(message)s'

handlers:
  console:
    class: logging.StreamHandler
    formatter: precise

loggers:
  synapse.storage.SQL:
    level: INFO

root:
  level: INFO
  handlers: [console]

disable_existing_loggers: false
EOF

rm -f "data/synapse/${MATRIX_DOMAIN}.log.config" 2>/dev/null || true

chmod 644 data/synapse/homeserver.yaml
chmod 644 data/synapse/log.config
chmod 640 "data/synapse/${MATRIX_DOMAIN}.signing.key"
chown -R 991:991 data/synapse 2>/dev/null || true

echo "[*] Generating MAS secrets template..."
docker run --rm \
  "${MAS_IMAGE}" \
  config generate > temp_mas_config.yaml

echo "[*] Extracting MAS secrets block..."
python3 - <<'PY'
from pathlib import Path

src = Path("temp_mas_config.yaml").read_text().splitlines()
out = []
capture = False

for line in src:
    if line.startswith("secrets:"):
        capture = True
    if capture:
        if out and line and not line.startswith(" ") and not line.startswith("\t") and not line.startswith("secrets:"):
            break
        out.append(line)

if not out:
    raise SystemExit("Could not extract MAS secrets block")

Path("data/mas/secrets.yaml").write_text("\n".join(out).rstrip() + "\n")
PY

echo "[*] Writing MAS config..."
cat > data/mas/config.yaml <<EOF
http:
  listeners:
    - name: web
      resources:
        - name: discovery
        - name: human
        - name: oauth
        - name: compat
        - name: graphql
        - name: assets
      binds:
        - address: "[::]:8080"
      proxy_protocol: false

    - name: internal
      resources:
        - name: health
        - name: adminapi
      binds:
        - address: "[::]:8081"
      proxy_protocol: false

  trusted_proxies:
    - 192.168.0.0/16
    - 172.16.0.0/12
    - 10.0.0.0/8
    - 127.0.0.1/8
    - fd00::/8
    - ::1/128

  public_base: "https://${MATRIX_DOMAIN}/"
  issuer: "https://${MATRIX_DOMAIN}/"

database:
  uri: "postgresql://${PG_APP_USER}:${PG_APP_PASSWORD}@${DB_HOST}:5432/mas?sslmode=disable"
  max_connections: 10
  min_connections: 0
  connect_timeout: 30
  idle_timeout: 600
  max_lifetime: 1800

email:
  from: '"Authentication Service" <noreply@${MATRIX_DOMAIN}>'
  reply_to: '"Authentication Service" <noreply@${MATRIX_DOMAIN}>'
  transport: blackhole

matrix:
  kind: synapse
  homeserver: "${MATRIX_DOMAIN}"
  secret: "${MAS_MATRIX_SECRET}"
  endpoint: "http://${SYNAPSE_HOST}:8008/"
EOF

cat data/mas/secrets.yaml >> data/mas/config.yaml

cat >> data/mas/config.yaml <<'EOF'

passwords:
  enabled: true
  schemes:
    - version: 1
      algorithm: argon2id
  minimum_complexity: 3

account:
  password_registration_enabled: false
EOF

rm -f data/mas/secrets.yaml
chmod 644 data/mas/config.yaml

echo "[*] Writing Ketesa config..."
cat > data/ketesa/config.json <<EOF
{
  "restrictBaseUrl": "https://${MATRIX_DOMAIN}",
  "corsCredentials": "same-origin"
}
EOF
chmod 644 data/ketesa/config.json

echo "[*] Writing Element Web config..."
cat > data/element-web/config.json <<EOF
{
  "default_server_name": "${MATRIX_DOMAIN}",
  "default_server_config": {
    "m.homeserver": {
      "base_url": "https://${MATRIX_DOMAIN}",
      "server_name": "${MATRIX_DOMAIN}"
    },
    "org.matrix.msc2965.authentication": {
      "issuer": "https://${MATRIX_DOMAIN}/",
      "account": "https://${MATRIX_DOMAIN}/account"
    }
  },
  "disable_custom_urls": true,
  "brand": "Element",
  "features": {
    "feature_group_calls": true,
    "feature_video_rooms": true,
    "feature_element_call_video_rooms": true
  },
  "element_call": {
    "use_exclusively": true
  }
}
EOF
chmod 644 data/element-web/config.json

echo "[*] Writing LiveKit config..."
cat > data/livekit/config.yaml <<EOF
port: 7880

redis:
  address: ${REDIS_HOST}:6379

rtc:
  udp_port: ${LIVEKIT_RTC_UDP_PORT}
  tcp_port: ${LIVEKIT_TCP_PORT}
  use_external_ip: ${LIVEKIT_USE_EXTERNAL_IP}
  enable_loopback_candidate: ${LIVEKIT_ENABLE_LOOPBACK_CANDIDATE}
  allow_tcp_fallback: ${LIVEKIT_ALLOW_TCP_FALLBACK}

turn:
  enabled: ${LIVEKIT_TURN_ENABLED}
  domain: ${LIVEKIT_TURN_DOMAIN}
  udp_port: ${LIVEKIT_TURN_UDP_PORT}
  tls_port: ${LIVEKIT_TURN_TLS_PORT}
  relay_range_start: ${LIVEKIT_TURN_RELAY_RANGE_START}
  relay_range_end: ${LIVEKIT_TURN_RELAY_RANGE_END}
  external_tls: ${LIVEKIT_TURN_EXTERNAL_TLS}
  cert_file: ${LIVEKIT_TURN_CERT_FILE}
  key_file: ${LIVEKIT_TURN_KEY_FILE}

keys:
  ${LK_API_KEY}: "${LK_SECRET}"

logging:
  json: ${LIVEKIT_LOG_JSON}
  level: ${LIVEKIT_LOG_LEVEL}
EOF
chmod 644 data/livekit/config.yaml

echo "[*] Writing admin helper script..."
cat > scripts/make-admin.sh <<'EOF'
#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  cd "${SCRIPT_DIR}"
elif [[ -f "${SCRIPT_DIR}/../.env" ]]; then
  cd "${SCRIPT_DIR}/.."
else
  cd "${SCRIPT_DIR}"
fi

if [[ ! -f .env ]]; then
  echo "[!] .env not found"
  exit 1
fi

set -a
. ./.env
set +a

if [[ -z "${MATRIX_DOMAIN:-}" || -z "${PG_SUPER_USER:-}" ]]; then
  echo "[!] MATRIX_DOMAIN and PG_SUPER_USER must exist in .env"
  exit 1
fi

read -rp "Enter admin localpart: " LOCALPART
LOCALPART="$(echo "${LOCALPART}" | tr -d '\r\n[:space:]')"

if [[ -z "${LOCALPART}" ]]; then
  echo "[!] localpart is required"
  exit 1
fi

if [[ ! "${LOCALPART}" =~ ^[a-z0-9._=-]+$ ]]; then
  echo "[!] localpart should be simple, for example: admin"
  exit 1
fi

while true; do
  read -rsp "Enter password for ${LOCALPART}: " PASSWORD
  echo
  read -rsp "Confirm password: " PASSWORD_CONFIRM
  echo

  if [[ -z "${PASSWORD}" ]]; then
    echo "[!] password cannot be empty"
    continue
  fi

  if [[ "${PASSWORD}" != "${PASSWORD_CONFIRM}" ]]; then
    echo "[!] passwords do not match"
    continue
  fi

  break
done

echo "[*] Creating or updating MAS admin user..."
if docker compose exec -T mas mas-cli --config=/data/config.yaml manage register-user \
  --yes \
  --password "${PASSWORD}" \
  --admin \
  --ignore-password-complexity \
  "${LOCALPART}" >/dev/null; then
  echo "[*] MAS user created as admin: ${LOCALPART}"
else
  echo "[*] User already exists or cannot be created directly; updating password/admin in MAS..."
  if docker compose exec -T mas mas-cli --config=/data/config.yaml manage set-password \
    "${LOCALPART}" "${PASSWORD}" --ignore-complexity >/dev/null; then
    docker compose exec -T mas mas-cli --config=/data/config.yaml manage promote-admin \
      "${LOCALPART}" >/dev/null
  else
    echo "[!] Failed to create or update MAS user: ${LOCALPART}"
    echo "    Try manual check:"
    echo "    docker compose exec -it mas mas-cli --config=/data/config.yaml manage register-user"
    exit 1
  fi
fi

echo "[*] Ensuring user is provisioned to Synapse..."
docker compose exec -T mas mas-cli --config=/data/config.yaml manage provision-all-users >/dev/null 2>&1 || true

MXID="@${LOCALPART}:${MATRIX_DOMAIN}"
FOUND=""
for _ in {1..30}; do
  FOUND="$(docker compose exec -T postgres psql -U "${PG_SUPER_USER}" -d synapse -tAc "SELECT 1 FROM users WHERE name='${MXID}' LIMIT 1;" | tr -d '[:space:]' || true)"
  if [[ "${FOUND}" == "1" ]]; then
    break
  fi
  sleep 2
done

if [[ "${FOUND}" != "1" ]]; then
  echo "[!] User was created in MAS but not found in Synapse DB yet: ${MXID}"
  echo "    Retry after a few seconds with: ./scripts/make-admin.sh"
  exit 1
fi

docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "${PG_SUPER_USER}" -d synapse <<SQL
UPDATE users
SET admin = 1
WHERE name = '${MXID}';

SELECT name, admin
FROM users
WHERE name = '${MXID}';
SQL

echo "[*] Done. MAS admin and Synapse admin are configured for ${MXID}."
EOF
chmod 700 scripts/make-admin.sh

echo "[*] Writing user purge helper script..."
cat > scripts/purge-user.sh <<'EOF'
#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  cd "${SCRIPT_DIR}"
elif [[ -f "${SCRIPT_DIR}/../.env" ]]; then
  cd "${SCRIPT_DIR}/.."
else
  cd "${SCRIPT_DIR}"
fi

usage() {
  echo "Usage: $0 [localpart|@user:domain] [--yes]"
  echo
  echo "Reclaims a local Matrix username for clean/test deployments."
  echo "It first uses supported MAS/Synapse cleanup paths where available,"
  echo "then removes the remaining MAS/Synapse username rows needed for reuse."
  echo
  echo "Optional:"
  echo "  SYNAPSE_ADMIN_ACCESS_TOKEN=...  run Synapse deactivate API with erase=true"
}

TARGET=""
ASSUME_YES=0

for arg in "$@"; do
  case "${arg}" in
    --yes|-y)
      ASSUME_YES=1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      if [[ -n "${TARGET}" ]]; then
        echo "[!] Unexpected argument: ${arg}"
        usage
        exit 1
      fi
      TARGET="${arg}"
      ;;
  esac
done

if [[ ! -f .env ]]; then
  echo "[!] .env not found. Run this from the deployment directory."
  exit 1
fi

set -a
. ./.env
set +a

: "${MATRIX_DOMAIN:?MATRIX_DOMAIN is missing from .env}"
: "${PG_SUPER_USER:?PG_SUPER_USER is missing from .env}"

DB_HOST="${DB_HOST:-elementx-postgres}"
SYNAPSE_HOST="${SYNAPSE_HOST:-elementx-synapse}"
MAS_HOST="${MAS_HOST:-elementx-mas}"

if [[ -z "${TARGET}" ]]; then
  read -rp "Enter localpart or MXID to purge: " TARGET
fi

TARGET="$(echo "${TARGET}" | tr -d '\r\n[:space:]')"
if [[ -z "${TARGET}" ]]; then
  echo "[!] target user is required"
  exit 1
fi

if [[ "${TARGET}" == @*:* ]]; then
  TARGET_DOMAIN="${TARGET##*:}"
  LOCALPART="${TARGET#@}"
  LOCALPART="${LOCALPART%%:*}"
  if [[ "${TARGET_DOMAIN}" != "${MATRIX_DOMAIN}" ]]; then
    echo "[!] Refusing to purge non-local MXID: ${TARGET}"
    echo "    This deployment owns only: ${MATRIX_DOMAIN}"
    exit 1
  fi
else
  LOCALPART="${TARGET}"
fi

if [[ ! "${LOCALPART}" =~ ^[a-z0-9._=-]+$ ]]; then
  echo "[!] localpart should be simple, for example: parsa"
  exit 1
fi

MXID="@${LOCALPART}:${MATRIX_DOMAIN}"

cat <<WARN
[!] Username reclaim for: ${MXID}

    Official Matrix/Synapse deactivation intentionally keeps usernames reserved.
    Use this only when you explicitly need to recreate the same local username.

    It will:
      1. Back up synapse and mas databases.
      2. Kill/lock the MAS user if it still exists.
      3. Use Synapse deactivate erase=true only if SYNAPSE_ADMIN_ACCESS_TOKEN is set.
      4. Remove the remaining MAS/Synapse rows that block username reuse.

    To continue, type exactly:
    DELETE ${MXID}
WARN

if (( ASSUME_YES == 0 )); then
  read -rp "Confirmation: " CONFIRM
  if [[ "${CONFIRM}" != "DELETE ${MXID}" ]]; then
    echo "[!] Confirmation did not match; aborting."
    exit 1
  fi
fi

BACKUP_DIR="data/purge-backups/${LOCALPART}-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "${BACKUP_DIR}"

echo "[*] Backing up databases to ${BACKUP_DIR}..."
docker compose exec -T postgres pg_dump -U "${PG_SUPER_USER}" -d synapse | gzip > "${BACKUP_DIR}/synapse.sql.gz"
docker compose exec -T postgres pg_dump -U "${PG_SUPER_USER}" -d mas | gzip > "${BACKUP_DIR}/mas.sql.gz"

echo "[*] MAS supported cleanup: kill sessions and lock/deactivate if possible..."
if docker compose ps --services --filter "status=running" | grep -qx mas; then
  docker compose exec -T mas mas-cli --config=/data/config.yaml manage kill-sessions "${LOCALPART}" >/dev/null 2>&1 || true
  docker compose exec -T mas mas-cli --config=/data/config.yaml manage lock-user "${LOCALPART}" --deactivate >/dev/null 2>&1 || true
fi

if [[ -n "${SYNAPSE_ADMIN_ACCESS_TOKEN:-}" ]]; then
  echo "[*] Synapse supported cleanup: deactivate erase=true via Admin API..."
  docker compose exec -T \
    -e SYNAPSE_ADMIN_ACCESS_TOKEN="${SYNAPSE_ADMIN_ACCESS_TOKEN}" \
    -e PURGE_MXID="${MXID}" \
    synapse python3 - <<'PY'
import json
import os
from urllib.parse import quote
from urllib.request import Request, urlopen

mxid = os.environ["PURGE_MXID"]
token = os.environ["SYNAPSE_ADMIN_ACCESS_TOKEN"]
url = "http://127.0.0.1:8008/_synapse/admin/v1/deactivate/" + quote(mxid, safe="")
body = json.dumps({"erase": True}).encode()
request = Request(
    url,
    data=body,
    headers={
        "Authorization": "Bearer " + token,
        "Content-Type": "application/json",
    },
    method="POST",
)
with urlopen(request, timeout=20) as response:
    print("OK Synapse deactivate:", response.status)
PY
else
  echo "[*] Synapse Admin API skipped: SYNAPSE_ADMIN_ACCESS_TOKEN is not set."
fi

echo "[*] Reclaiming MAS username rows using FK-aware SQL..."
docker compose exec -T postgres psql -qv ON_ERROR_STOP=1 -U "${PG_SUPER_USER}" -d mas \
  -v localpart="${LOCALPART}" \
  -v mxid="${MXID}" <<'SQL'
CREATE TEMP TABLE purge_seed_values(value text PRIMARY KEY);
INSERT INTO purge_seed_values(value)
VALUES (lower(:'localpart')), (lower(:'mxid'))
ON CONFLICT DO NOTHING;

CREATE TEMP TABLE purge_mas_user_ids(user_id text PRIMARY KEY);
INSERT INTO purge_mas_user_ids(user_id)
SELECT user_id::text
FROM users
WHERE lower(username) = lower(:'localpart')
ON CONFLICT DO NOTHING;

CREATE TEMP TABLE purge_mas_ids(value text PRIMARY KEY);
INSERT INTO purge_mas_ids(value)
SELECT user_id FROM purge_mas_user_ids
ON CONFLICT DO NOTHING;

CREATE TEMP TABLE purge_row_refs(
  relid oid NOT NULL,
  tid text NOT NULL,
  depth integer NOT NULL DEFAULT 0,
  PRIMARY KEY (relid, tid)
);

INSERT INTO purge_row_refs(relid, tid, depth)
SELECT 'public.users'::regclass::oid, ctid::text, 0
FROM users
WHERE lower(username) = lower(:'localpart');

DO $purge$
DECLARE
  col record;
BEGIN
  FOR col IN
    SELECT c.oid AS relid, n.nspname AS schema_name, c.relname AS table_name, a.attname AS column_name
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_attribute a ON a.attrelid = c.oid
    WHERE n.nspname = 'public'
      AND c.relkind = 'r'
      AND NOT a.attisdropped
      AND a.attnum > 0
      AND c.relname <> 'users'
      AND a.attname IN ('user_id', 'username', 'user_name', 'localpart', 'mxid')
  LOOP
    EXECUTE format(
      'INSERT INTO purge_row_refs(relid, tid, depth)
       SELECT $1::oid, t.ctid::text, 0
       FROM %I.%I t
       WHERE lower(t.%I::text) IN (SELECT value FROM purge_seed_values)
          OR t.%I::text IN (SELECT user_id FROM purge_mas_user_ids)
       ON CONFLICT DO NOTHING',
      col.schema_name,
      col.table_name,
      col.column_name,
      col.column_name
    )
    USING col.relid;
  END LOOP;
END
$purge$;

DO $purge$
DECLARE
  pass integer := 0;
  changed integer := 0;
  inserted integer := 0;
  col record;
BEGIN
  LOOP
    pass := pass + 1;
    changed := 0;

    FOR col IN
      SELECT c.oid AS relid, n.nspname AS schema_name, c.relname AS table_name, a.attname AS column_name
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_attribute a ON a.attrelid = c.oid
      WHERE n.nspname = 'public'
        AND c.relkind = 'r'
        AND NOT a.attisdropped
        AND a.attnum > 0
        AND (
          a.attname IN ('username', 'user_name', 'localpart', 'mxid')
          OR a.attname IN (
            'user_id',
            'user_session_id',
            'session_id',
            'oauth2_session_id',
            'oauth2_access_token_id',
            'oauth2_refresh_token_id',
            'oauth2_authorization_grant_id',
            'compat_session_id',
            'compat_access_token_id',
            'compat_refresh_token_id',
            'user_password_id',
            'authentication_id',
            'user_email_id',
            'user_email_authentication_id',
            'user_registration_id',
            'user_recovery_ticket_id',
            'upstream_oauth_session_id',
            'upstream_oauth_link_id',
            'personal_access_token_id'
          )
        )
    LOOP
      EXECUTE format(
        'INSERT INTO purge_row_refs(relid, tid, depth)
         SELECT $1::oid, t.ctid::text, 0
         FROM %I.%I t
         WHERE lower(t.%I::text) IN (SELECT value FROM purge_seed_values)
            OR t.%I::text IN (SELECT value FROM purge_mas_ids)
         ON CONFLICT DO NOTHING',
        col.schema_name,
        col.table_name,
        col.column_name,
        col.column_name
      )
      USING col.relid;

      GET DIAGNOSTICS inserted = ROW_COUNT;
      changed := changed + inserted;

      EXECUTE format(
        'INSERT INTO purge_mas_ids(value)
         SELECT DISTINCT t.%I::text
         FROM %I.%I t
         JOIN purge_row_refs r ON r.relid = $1::oid AND r.tid = t.ctid::text
         WHERE t.%I IS NOT NULL
         ON CONFLICT DO NOTHING',
        col.column_name,
        col.schema_name,
        col.table_name,
        col.column_name
      )
      USING col.relid;

      GET DIAGNOSTICS inserted = ROW_COUNT;
      changed := changed + inserted;
    END LOOP;

    EXIT WHEN changed = 0 OR pass >= 20;
  END LOOP;
END
$purge$;

DO $purge$
DECLARE
  pass integer := 0;
  total_inserted integer := 0;
  inserted integer := 0;
  fk record;
  blocker record;
  join_clause text;
  deleted_rows integer := 0;
  target_count integer := 0;
BEGIN
  SELECT count(*) INTO target_count FROM purge_row_refs;
  RAISE NOTICE 'MAS seed rows selected: %', target_count;

  LOOP
    pass := pass + 1;
    total_inserted := 0;

    FOR fk IN
      SELECT
        con.conrelid AS child_relid,
        con.confrelid AS parent_relid,
        child_ns.nspname AS child_schema,
        child_cls.relname AS child_table,
        parent_ns.nspname AS parent_schema,
        parent_cls.relname AS parent_table,
        con.conkey,
        con.confkey
      FROM pg_constraint con
      JOIN pg_class child_cls ON child_cls.oid = con.conrelid
      JOIN pg_namespace child_ns ON child_ns.oid = child_cls.relnamespace
      JOIN pg_class parent_cls ON parent_cls.oid = con.confrelid
      JOIN pg_namespace parent_ns ON parent_ns.oid = parent_cls.relnamespace
      WHERE con.contype = 'f'
        AND child_ns.nspname = 'public'
        AND parent_ns.nspname = 'public'
    LOOP
      SELECT string_agg(
        format('c.%I IS NOT DISTINCT FROM p.%I', child_att.attname, parent_att.attname),
        ' AND '
        ORDER BY child_key.ord
      )
      INTO join_clause
      FROM unnest(fk.conkey) WITH ORDINALITY AS child_key(attnum, ord)
      JOIN unnest(fk.confkey) WITH ORDINALITY AS parent_key(attnum, ord) USING (ord)
      JOIN pg_attribute child_att ON child_att.attrelid = fk.child_relid AND child_att.attnum = child_key.attnum
      JOIN pg_attribute parent_att ON parent_att.attrelid = fk.parent_relid AND parent_att.attnum = parent_key.attnum;

      EXECUTE format(
      'INSERT INTO purge_row_refs(relid, tid, depth)
       SELECT $1::oid, c.ctid::text, $2
       FROM %I.%I c
       JOIN %I.%I p ON %s
       JOIN purge_row_refs r ON r.relid = $3::oid AND r.tid = p.ctid::text
       ON CONFLICT (relid, tid) DO UPDATE
       SET depth = EXCLUDED.depth
       WHERE purge_row_refs.depth < EXCLUDED.depth',
        fk.child_schema,
        fk.child_table,
        fk.parent_schema,
        fk.parent_table,
        join_clause
      )
      USING fk.child_relid, pass, fk.parent_relid;

      GET DIAGNOSTICS inserted = ROW_COUNT;
      total_inserted := total_inserted + inserted;
    END LOOP;

    EXIT WHEN total_inserted = 0 OR pass >= 30;
  END LOOP;

  pass := 0;
  LOOP
    pass := pass + 1;
    total_inserted := 0;

    FOR fk IN
      SELECT refs.relid, max(refs.depth) AS max_depth, ns.nspname AS schema_name, cls.relname AS table_name, count(*) AS row_count
      FROM purge_row_refs refs
      JOIN pg_class cls ON cls.oid = refs.relid
      JOIN pg_namespace ns ON ns.oid = cls.relnamespace
      GROUP BY refs.relid, ns.nspname, cls.relname
      ORDER BY max(refs.depth) DESC, cls.relname ASC
    LOOP
      BEGIN
        EXECUTE format(
          'WITH victims AS (
             SELECT t.ctid::text AS tid
             FROM %I.%I t
             JOIN purge_row_refs r ON r.relid = $1::oid AND r.tid = t.ctid::text
           ),
           deleted AS (
             DELETE FROM %I.%I t
             USING victims v
             WHERE t.ctid::text = v.tid
             RETURNING t.ctid::text AS tid
           )
           DELETE FROM purge_row_refs r
           USING deleted d
           WHERE r.relid = $1::oid
             AND r.tid = d.tid',
          fk.schema_name,
          fk.table_name,
          fk.schema_name,
          fk.table_name
        )
        USING fk.relid;

        GET DIAGNOSTICS deleted_rows = ROW_COUNT;
        total_inserted := total_inserted + deleted_rows;
        IF deleted_rows > 0 THEN
          RAISE NOTICE 'MAS deleted % row(s) from %.%', deleted_rows, fk.schema_name, fk.table_name;
        END IF;

        EXECUTE format(
          'DELETE FROM purge_row_refs r
           WHERE r.relid = $1::oid
             AND NOT EXISTS (
               SELECT 1
               FROM %I.%I t
               WHERE t.ctid::text = r.tid
             )',
          fk.schema_name,
          fk.table_name
        )
        USING fk.relid;

        GET DIAGNOSTICS inserted = ROW_COUNT;
        total_inserted := total_inserted + inserted;
        IF inserted > 0 THEN
          RAISE NOTICE 'MAS cleared % stale purge ref(s) for %.%', inserted, fk.schema_name, fk.table_name;
        END IF;
      EXCEPTION WHEN foreign_key_violation THEN
        RAISE NOTICE 'MAS postponed %.% because dependent rows still exist', fk.schema_name, fk.table_name;

        FOR blocker IN
          SELECT
            con.conrelid AS child_relid,
            con.confrelid AS parent_relid,
            child_ns.nspname AS child_schema,
            child_cls.relname AS child_table,
            parent_ns.nspname AS parent_schema,
            parent_cls.relname AS parent_table,
            con.conkey,
            con.confkey
          FROM pg_constraint con
          JOIN pg_class child_cls ON child_cls.oid = con.conrelid
          JOIN pg_namespace child_ns ON child_ns.oid = child_cls.relnamespace
          JOIN pg_class parent_cls ON parent_cls.oid = con.confrelid
          JOIN pg_namespace parent_ns ON parent_ns.oid = parent_cls.relnamespace
          WHERE con.contype = 'f'
            AND con.confrelid = fk.relid
            AND child_ns.nspname = 'public'
            AND parent_ns.nspname = 'public'
        LOOP
          SELECT string_agg(
            format('c.%I IS NOT DISTINCT FROM p.%I', child_att.attname, parent_att.attname),
            ' AND '
            ORDER BY child_key.ord
          )
          INTO join_clause
          FROM unnest(blocker.conkey) WITH ORDINALITY AS child_key(attnum, ord)
          JOIN unnest(blocker.confkey) WITH ORDINALITY AS parent_key(attnum, ord) USING (ord)
          JOIN pg_attribute child_att ON child_att.attrelid = blocker.child_relid AND child_att.attnum = child_key.attnum
          JOIN pg_attribute parent_att ON parent_att.attrelid = blocker.parent_relid AND parent_att.attnum = parent_key.attnum;

          EXECUTE format(
            'INSERT INTO purge_row_refs(relid, tid, depth)
             SELECT $1::oid, c.ctid::text, $2
             FROM %I.%I c
             JOIN %I.%I p ON %s
             JOIN purge_row_refs r ON r.relid = $3::oid AND r.tid = p.ctid::text
             ON CONFLICT (relid, tid) DO UPDATE
             SET depth = EXCLUDED.depth
             WHERE purge_row_refs.depth < EXCLUDED.depth',
            blocker.child_schema,
            blocker.child_table,
            blocker.parent_schema,
            blocker.parent_table,
            join_clause
          )
          USING blocker.child_relid, fk.max_depth + 1, blocker.parent_relid;

          GET DIAGNOSTICS inserted = ROW_COUNT;
          total_inserted := total_inserted + inserted;
          IF inserted > 0 THEN
            RAISE NOTICE 'MAS queued % row(s) from %.% as blocker(s)', inserted, blocker.child_schema, blocker.child_table;
          END IF;
        END LOOP;
      END;
    END LOOP;

    SELECT count(*) INTO target_count FROM purge_row_refs;
    EXIT WHEN target_count = 0;

    IF total_inserted = 0 OR pass >= 20 THEN
      FOR fk IN
        SELECT refs.relid, ns.nspname AS schema_name, cls.relname AS table_name, count(*) AS row_count
        FROM purge_row_refs refs
        JOIN pg_class cls ON cls.oid = refs.relid
        JOIN pg_namespace ns ON ns.oid = cls.relnamespace
        GROUP BY refs.relid, ns.nspname, cls.relname
        ORDER BY row_count DESC, cls.relname ASC
      LOOP
        RAISE NOTICE 'MAS remaining %.%: % row(s)', fk.schema_name, fk.table_name, fk.row_count;
      END LOOP;

      RAISE EXCEPTION 'MAS purge could not remove % referenced row(s) after % delete pass(es)', target_count, pass;
    END IF;
  END LOOP;
END
$purge$;

DO $purge$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM users
    WHERE lower(username) IN (SELECT value FROM purge_seed_values)
  ) THEN
    RAISE EXCEPTION 'MAS username still exists after purge';
  END IF;
END
$purge$;
SQL

echo "[*] Reclaiming Synapse username rows using conservative SQL..."
docker compose exec -T postgres psql -qv ON_ERROR_STOP=1 -U "${PG_SUPER_USER}" -d synapse \
  -v localpart="${LOCALPART}" \
  -v mxid="${MXID}" <<'SQL'
CREATE TEMP TABLE purge_seed_values(value text PRIMARY KEY);
INSERT INTO purge_seed_values(value)
VALUES (lower(:'localpart')), (lower(:'mxid'))
ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION pg_temp.purge_synapse_value(p_table text, p_column text)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
  deleted_rows integer := 0;
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = p_table
      AND column_name = p_column
  ) THEN
    EXECUTE format(
      'DELETE FROM %I WHERE lower(%I::text) IN (SELECT value FROM purge_seed_values)',
      p_table,
      p_column
    );
    GET DIAGNOSTICS deleted_rows = ROW_COUNT;
    IF deleted_rows > 0 THEN
      RAISE NOTICE 'Synapse deleted % row(s) from %.%', deleted_rows, p_table, p_column;
    END IF;
  END IF;

  RETURN deleted_rows;
END;
$$;

WITH purge(deleted_rows) AS (
  SELECT pg_temp.purge_synapse_value('access_tokens', 'user_id') UNION ALL
  SELECT pg_temp.purge_synapse_value('refresh_tokens', 'user_id') UNION ALL
  SELECT pg_temp.purge_synapse_value('devices', 'user_id') UNION ALL
  SELECT pg_temp.purge_synapse_value('device_inbox', 'user_id') UNION ALL
  SELECT pg_temp.purge_synapse_value('device_lists_stream', 'user_id') UNION ALL
  SELECT pg_temp.purge_synapse_value('device_lists_outbound_pokes', 'user_id') UNION ALL
  SELECT pg_temp.purge_synapse_value('e2e_device_keys', 'user_id') UNION ALL
  SELECT pg_temp.purge_synapse_value('e2e_one_time_keys_json', 'user_id') UNION ALL
  SELECT pg_temp.purge_synapse_value('e2e_cross_signing_keys', 'user_id') UNION ALL
  SELECT pg_temp.purge_synapse_value('e2e_cross_signing_signatures', 'user_id') UNION ALL
  SELECT pg_temp.purge_synapse_value('e2e_cross_signing_signatures', 'target_user_id') UNION ALL
  SELECT pg_temp.purge_synapse_value('account_data', 'user_id') UNION ALL
  SELECT pg_temp.purge_synapse_value('room_account_data', 'user_id') UNION ALL
  SELECT pg_temp.purge_synapse_value('pushers', 'user_name') UNION ALL
  SELECT pg_temp.purge_synapse_value('pushers', 'user_id') UNION ALL
  SELECT pg_temp.purge_synapse_value('user_filters', 'user_id') UNION ALL
  SELECT pg_temp.purge_synapse_value('user_filters', 'full_user_id') UNION ALL
  SELECT pg_temp.purge_synapse_value('profiles', 'full_user_id') UNION ALL
  SELECT pg_temp.purge_synapse_value('profiles', 'user_id') UNION ALL
  SELECT pg_temp.purge_synapse_value('user_directory', 'user_id') UNION ALL
  SELECT pg_temp.purge_synapse_value('user_directory_search', 'user_id') UNION ALL
  SELECT pg_temp.purge_synapse_value('erased_users', 'user_id') UNION ALL
  SELECT pg_temp.purge_synapse_value('monthly_active_users', 'user_id') UNION ALL
  SELECT pg_temp.purge_synapse_value('user_ips', 'user_id') UNION ALL
  SELECT pg_temp.purge_synapse_value('user_threepids', 'user_id') UNION ALL
  SELECT pg_temp.purge_synapse_value('user_external_ids', 'user_id') UNION ALL
  SELECT pg_temp.purge_synapse_value('ignored_users', 'ignorer_user_id') UNION ALL
  SELECT pg_temp.purge_synapse_value('ignored_users', 'ignored_user_id')
)
SELECT COALESCE(sum(deleted_rows), 0) AS synapse_deleted_rows
FROM purge;

DELETE FROM users
WHERE lower(name) = lower(:'mxid');

DO $purge$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM users
    WHERE lower(name) IN (SELECT value FROM purge_seed_values)
  ) THEN
    RAISE EXCEPTION 'Synapse username still exists after purge';
  END IF;
END
$purge$;
SQL

echo "[*] Verifying username is free in MAS and Synapse..."
docker compose exec -T postgres psql -qAtv ON_ERROR_STOP=1 -U "${PG_SUPER_USER}" -d mas \
  -v localpart="${LOCALPART}" <<'SQL'
SELECT 'mas_users=' || count(*) FROM users WHERE lower(username) = lower(:'localpart');
SQL

docker compose exec -T postgres psql -qAtv ON_ERROR_STOP=1 -U "${PG_SUPER_USER}" -d synapse \
  -v mxid="${MXID}" <<'SQL'
SELECT 'synapse_users=' || count(*) FROM users WHERE lower(name) = lower(:'mxid');
SQL

cat <<DONE
[*] Purge complete for ${MXID}.
[*] Backups:
    ${BACKUP_DIR}/synapse.sql.gz
    ${BACKUP_DIR}/mas.sql.gz

Next test:
  docker compose exec -it mas mas-cli --config=/data/config.yaml manage register-user
DONE
EOF
chmod 700 scripts/purge-user.sh

echo "[*] Validating generated configs..."
grep -q "host: \"${DB_HOST}\"" data/synapse/homeserver.yaml
grep -q "@${DB_HOST}:5432/mas" data/mas/config.yaml
grep -q "^matrix:$" data/mas/config.yaml
grep -q "kind: synapse" data/mas/config.yaml
grep -q "homeserver: \"${MATRIX_DOMAIN}\"" data/mas/config.yaml
grep -q "^secrets:$" data/mas/config.yaml
grep -q "endpoint: \"http://${MAS_HOST}:8080\"" data/synapse/homeserver.yaml
grep -q "msc3266_enabled: true" data/synapse/homeserver.yaml
grep -q "msc4222_enabled: true" data/synapse/homeserver.yaml
grep -q "msc4143_enabled: true" data/synapse/homeserver.yaml
grep -q "max_event_delay_duration: 24h" data/synapse/homeserver.yaml
grep -q "^rc_message:$" data/synapse/homeserver.yaml
grep -q "^rc_delayed_event_mgmt:$" data/synapse/homeserver.yaml
grep -q "livekit_service_url: \"https://${MATRIX_DOMAIN}/livekit/jwt\"" data/synapse/homeserver.yaml
grep -Fq "names: [client, federation, openid]" data/synapse/homeserver.yaml
grep -q "endpoint: \"http://${SYNAPSE_HOST}:8008/\"" data/mas/config.yaml
grep -q "\"restrictBaseUrl\": \"https://${MATRIX_DOMAIN}\"" data/ketesa/config.json
grep -q "\"default_server_name\": \"${MATRIX_DOMAIN}\"" data/element-web/config.json
grep -q "\"server_name\": \"${MATRIX_DOMAIN}\"" data/element-web/config.json
grep -q "\"feature_group_calls\": true" data/element-web/config.json
grep -q "\"feature_video_rooms\": true" data/element-web/config.json
grep -q "\"feature_element_call_video_rooms\": true" data/element-web/config.json
grep -q "\"use_exclusively\": true" data/element-web/config.json
grep -q "^LIVEKIT_URL=wss://${MATRIX_DOMAIN}${LIVEKIT_URL_PATH}$" .env
grep -q "^LIVEKIT_JWT_BASE_URL=https://${MATRIX_DOMAIN}${LIVEKIT_JWT_BASE_PATH}$" .env
grep -q "^LIVEKIT_RTC_UDP_PORT=${LIVEKIT_RTC_UDP_PORT}$" .env
grep -q "^LIVEKIT_TCP_PORT=${LIVEKIT_TCP_PORT}$" .env
grep -q "^LIVEKIT_USE_EXTERNAL_IP=${LIVEKIT_USE_EXTERNAL_IP}$" .env
grep -q "^LIVEKIT_ENABLE_LOOPBACK_CANDIDATE=${LIVEKIT_ENABLE_LOOPBACK_CANDIDATE}$" .env
grep -q "^LIVEKIT_ALLOW_TCP_FALLBACK=${LIVEKIT_ALLOW_TCP_FALLBACK}$" .env
grep -q "^LIVEKIT_TURN_ENABLED=${LIVEKIT_TURN_ENABLED}$" .env
grep -q "^LIVEKIT_TURN_DOMAIN=${LIVEKIT_TURN_DOMAIN}$" .env
grep -q "^LIVEKIT_TURN_UDP_PORT=${LIVEKIT_TURN_UDP_PORT}$" .env
grep -q "^LIVEKIT_TURN_TLS_PORT=${LIVEKIT_TURN_TLS_PORT}$" .env
grep -q "^LIVEKIT_TURN_RELAY_RANGE_START=${LIVEKIT_TURN_RELAY_RANGE_START}$" .env
grep -q "^LIVEKIT_TURN_RELAY_RANGE_END=${LIVEKIT_TURN_RELAY_RANGE_END}$" .env
grep -q "^LIVEKIT_TURN_EXTERNAL_TLS=${LIVEKIT_TURN_EXTERNAL_TLS}$" .env
grep -q "^LIVEKIT_TLS_CERT_DIR=${LIVEKIT_TLS_CERT_DIR}$" .env
grep -q "^LIVEKIT_TURN_CERT_FILE=${LIVEKIT_TURN_CERT_FILE}$" .env
grep -q "^LIVEKIT_TURN_KEY_FILE=${LIVEKIT_TURN_KEY_FILE}$" .env
grep -q "^LIVEKIT_LOG_JSON=${LIVEKIT_LOG_JSON}$" .env
grep -q "^LIVEKIT_LOG_LEVEL=${LIVEKIT_LOG_LEVEL}$" .env
grep -q "^KETESA_IMAGE=${KETESA_IMAGE}$" .env
grep -q "^POSTGRES_IMAGE=${POSTGRES_IMAGE}$" .env
grep -q "^REDIS_IMAGE=${REDIS_IMAGE}$" .env
grep -q "^RESTART_POLICY=${RESTART_POLICY}$" .env
grep -q "^POSTGRES_DATA_PATH=${POSTGRES_DATA_PATH}$" .env
grep -q "^SYNAPSE_DATA_PATH=${SYNAPSE_DATA_PATH}$" .env
grep -q "^MAS_DATA_PATH=${MAS_DATA_PATH}$" .env
grep -q "^LIVEKIT_DATA_PATH=${LIVEKIT_DATA_PATH}$" .env
grep -q "^KETESA_CONFIG_PATH=${KETESA_CONFIG_PATH}$" .env
grep -q "^ELEMENT_WEB_CONFIG_PATH=${ELEMENT_WEB_CONFIG_PATH}$" .env
grep -q "^POSTGRES_INIT_SQL_PATH=${POSTGRES_INIT_SQL_PATH}$" .env
grep -q "udp_port: ${LIVEKIT_RTC_UDP_PORT}" data/livekit/config.yaml
grep -q "tcp_port: ${LIVEKIT_TCP_PORT}" data/livekit/config.yaml
grep -q "use_external_ip: ${LIVEKIT_USE_EXTERNAL_IP}" data/livekit/config.yaml
grep -q "enable_loopback_candidate: ${LIVEKIT_ENABLE_LOOPBACK_CANDIDATE}" data/livekit/config.yaml
grep -q "allow_tcp_fallback: ${LIVEKIT_ALLOW_TCP_FALLBACK}" data/livekit/config.yaml
grep -q "enabled: ${LIVEKIT_TURN_ENABLED}" data/livekit/config.yaml
grep -q "domain: ${LIVEKIT_TURN_DOMAIN}" data/livekit/config.yaml
grep -q "udp_port: ${LIVEKIT_TURN_UDP_PORT}" data/livekit/config.yaml
grep -q "tls_port: ${LIVEKIT_TURN_TLS_PORT}" data/livekit/config.yaml
grep -q "relay_range_start: ${LIVEKIT_TURN_RELAY_RANGE_START}" data/livekit/config.yaml
grep -q "relay_range_end: ${LIVEKIT_TURN_RELAY_RANGE_END}" data/livekit/config.yaml
grep -q "external_tls: ${LIVEKIT_TURN_EXTERNAL_TLS}" data/livekit/config.yaml
grep -q "cert_file: ${LIVEKIT_TURN_CERT_FILE}" data/livekit/config.yaml
grep -q "key_file: ${LIVEKIT_TURN_KEY_FILE}" data/livekit/config.yaml
grep -q "json: ${LIVEKIT_LOG_JSON}" data/livekit/config.yaml
grep -q "level: ${LIVEKIT_LOG_LEVEL}" data/livekit/config.yaml
grep -Fq 'image: ${POSTGRES_IMAGE}' docker-compose.yml
grep -Fq 'container_name: ${DB_HOST}' docker-compose.yml
grep -Fq '${POSTGRES_DATA_PATH}:/var/lib/postgresql/data' docker-compose.yml
grep -Fq '${POSTGRES_INIT_SQL_PATH}:/docker-entrypoint-initdb.d/01-init.sql:ro' docker-compose.yml
grep -Fq 'image: ${KETESA_IMAGE}' docker-compose.yml
grep -Fq '${KETESA_CONFIG_PATH}:/var/public/config.json:ro' docker-compose.yml
grep -Fq '${LIVEKIT_TLS_CERT_DIR}:/etc/lk-certs:ro' docker-compose.yml
grep -Fq '${LIVEKIT_TCP_PORT}:${LIVEKIT_TCP_PORT}/tcp' docker-compose.yml
grep -Fq '${LIVEKIT_RTC_UDP_PORT}:${LIVEKIT_RTC_UDP_PORT}/udp' docker-compose.yml
grep -Fq '${LIVEKIT_TURN_UDP_PORT}:${LIVEKIT_TURN_UDP_PORT}/udp' docker-compose.yml
grep -Fq '${LIVEKIT_TURN_TLS_PORT}:${LIVEKIT_TURN_TLS_PORT}/tcp' docker-compose.yml
grep -Fq '${LIVEKIT_TURN_RELAY_RANGE_START}-${LIVEKIT_TURN_RELAY_RANGE_END}:${LIVEKIT_TURN_RELAY_RANGE_START}-${LIVEKIT_TURN_RELAY_RANGE_END}/udp' docker-compose.yml
grep -q "element-web:" docker-compose.yml
grep -q "server_name ${MATRIX_DOMAIN};" "${NGINX_DEFAULT_CONF_LOCAL_PATH}"
grep -q "location = /_matrix/client/unstable/org.matrix.msc4143/rtc/transports" "${NGINX_DEFAULT_CONF_LOCAL_PATH}"
grep -q "location = /_matrix/client/v1/rtc/transports" "${NGINX_DEFAULT_CONF_LOCAL_PATH}"
grep -q "rtc_transports" "${NGINX_DEFAULT_CONF_LOCAL_PATH}"
grep -q "location \^~ ${LIVEKIT_URL_PATH}/" "${NGINX_DEFAULT_CONF_LOCAL_PATH}"
grep -q "location = /web" "${NGINX_DEFAULT_CONF_LOCAL_PATH}"
grep -q "location \^~ /web/" "${NGINX_DEFAULT_CONF_LOCAL_PATH}"
grep -q "livekit_service_url\":\"https://${MATRIX_DOMAIN}${LIVEKIT_JWT_BASE_PATH}" "${NGINX_DEFAULT_CONF_LOCAL_PATH}"
[[ -x scripts/purge-user.sh ]]

echo "[*] Validating docker compose file..."
docker compose config >/dev/null

wait_for_container() {
  local name="$1"
  local timeout="${2:-120}"
  local elapsed=0
  local status=""

  while (( elapsed < timeout )); do
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${name}" 2>/dev/null || true)"
    status="${status:-unknown}"

    if [[ "${status}" == "healthy" || "${status}" == "running" ]]; then
      return 0
    fi
    if [[ "${status}" == "unhealthy" || "${status}" == "exited" || "${status}" == "dead" ]]; then
      echo "[!] Container ${name} is in bad state: ${status}"
      return 1
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done

  echo "[!] Timeout waiting for ${name}"
  return 1
}

test_db_from_synapse_image() {
  local dbname="$1"
  docker compose run --rm --no-deps --entrypoint sh synapse -lc "python3 - <<'PY'
import psycopg2
conn = psycopg2.connect(
    user='${PG_APP_USER}',
    password='${PG_APP_PASSWORD}',
    host='${DB_HOST}',
    port=5432,
    dbname='${dbname}',
)
print('OK ${dbname}')
conn.close()
PY"
}

ensure_container_on_nginx_network() {
  local name="$1"
  local attached=""

  attached="$(docker inspect -f '{{if index .NetworkSettings.Networks "nginx"}}yes{{else}}no{{end}}' "${name}" 2>/dev/null || true)"
  if [[ "${attached}" != "yes" ]]; then
    echo "[!] ${name} is not attached to the external nginx network."
    return 1
  fi

  echo "OK ${name} is attached to nginx network"
}

test_tcp_from_synapse() {
  local host="$1"
  local port="$2"
  local label="$3"

  docker compose exec -T synapse python3 - <<PY
import socket

host = "${host}"
port = int("${port}")
label = "${label}"

with socket.create_connection((host, port), timeout=5):
    pass

print(f"OK {label}: tcp {host}:{port}")
PY
}

test_http_from_synapse() {
  local url="$1"
  local label="$2"

  docker compose exec -T synapse python3 - <<PY
from urllib.request import urlopen

url = "${url}"
label = "${label}"

response = urlopen(url, timeout=5)
if response.status >= 400:
    raise SystemExit(f"{label} returned HTTP {response.status}")

print(f"OK {label}: HTTP {response.status}")
PY
}

echo "[*] Starting postgres and redis..."
docker compose up -d postgres redis

wait_for_container "${DB_HOST}" 120
wait_for_container "${REDIS_HOST}" 60

echo "[*] Smoke testing database connectivity from the synapse image..."
test_db_from_synapse_image "synapse"
test_db_from_synapse_image "mas"

echo "[*] Starting all services..."
docker compose up -d

wait_for_container "${SYNAPSE_HOST}" 120
wait_for_container "${MAS_HOST}" 60
wait_for_container "${LIVEKIT_HOST}" 60
wait_for_container "${LIVEKIT_JWT_HOST}" 60
wait_for_container "${ELEMENT_WEB_HOST}" 60
wait_for_container "${KETESA_HOST}" 60

echo "[*] Smoke testing LiveKit and MatrixRTC helper reachability..."
ensure_container_on_nginx_network "${LIVEKIT_HOST}"
ensure_container_on_nginx_network "${LIVEKIT_JWT_HOST}"
test_tcp_from_synapse "${LIVEKIT_HOST}" 7880 "LiveKit SFU"
test_tcp_from_synapse "${LIVEKIT_HOST}" "${LIVEKIT_TCP_PORT}" "LiveKit ICE TCP fallback"
test_tcp_from_synapse "${LIVEKIT_HOST}" "${LIVEKIT_TURN_TLS_PORT}" "LiveKit TURN TLS"
test_http_from_synapse "http://${LIVEKIT_JWT_HOST}:8080/healthz" "LiveKit JWT health"

# Give services a short silent stabilization window before final health gate.
for _ in {1..15}; do
  if ! docker compose ps | grep -Eqi 'Restarting|Exited|Dead'; then
    break
  fi
  sleep 2
done

if docker compose ps | grep -Eqi 'Restarting|Exited|Dead'; then
  echo "[!] One or more services are not stable."
  exit 1
fi

if docker compose logs --since=120s synapse mas 2>/dev/null | grep -Eqi 'password authentication failed|could not connect to the database|OperationalError'; then
  echo "[!] Database connectivity errors were detected in synapse or mas logs."
  exit 1
fi

cat > "${MARKER_FILE}" <<EOF
domain=${MATRIX_DOMAIN}
completed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
chmod 600 "${MARKER_FILE}"

echo "====================================================================="
echo " Check Service Status:"
echo "   docker compose ps"
echo "   docker compose logs -f synapse mas livekit livekit-jwt ketesa"
echo
echo " Next steps:"
echo
echo " 1) Firewall"
echo "   Allow UDP ${LIVEKIT_RTC_UDP_PORT}"
echo "   Allow TCP ${LIVEKIT_TCP_PORT}"
echo "   Allow UDP ${LIVEKIT_TURN_UDP_PORT}"
echo "   Allow TCP ${LIVEKIT_TURN_TLS_PORT}"
echo "   Allow UDP ${LIVEKIT_TURN_RELAY_RANGE_START}-${LIVEKIT_TURN_RELAY_RANGE_END}"
echo
echo " 2) Nginx"
echo "   Copy these files into your existing nginx-proxy container config:"
echo "   cp $(pwd)/${NGINX_DEFAULT_CONF_LOCAL_PATH} ${NGINX_DEFAULT_CONF_TARGET_PATH}"
echo "   cp $(pwd)/${ADMIN_ALLOWLIST_LOCAL_PATH} ${ADMIN_ALLOWLIST_TARGET_PATH}"
echo "   docker exec nginx-proxy nginx -t"
echo "   docker exec nginx-proxy nginx -s reload"
echo "   To add an admin IP later: add 'allow <IP>;' to admin-allowlist.inc, then reload nginx."
echo
echo " 3) Create admin"
echo "   ./scripts/make-admin.sh"
echo
echo " 4) Create normal users"
echo "   Preferred: use Ketesa Admin UI"
echo "   CLI: docker compose exec -it mas mas-cli --config=/data/config.yaml manage register-user"
echo
echo " 5) Fully delete/reclaim a username"
echo "   Ketesa/Admin delete does not fully free usernames in MAS/Synapse."
echo "   Use this when a deleted username must be created again:"
echo "   ./scripts/purge-user.sh"
echo
echo " Setup complete."
echo " Domain: ${MATRIX_DOMAIN}"
echo " Server IP: ${SERVER_IP}"
echo
echo " Links:"
echo "   Element/MAS:   https://${MATRIX_DOMAIN}/"
echo "   Element Web:   https://${MATRIX_DOMAIN}/web/"
echo "   Ketesa Admin:  https://${MATRIX_DOMAIN}/admin/"
echo "====================================================================="
