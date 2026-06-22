#!/bin/bash
# ============================================================
# ilo-cert-deploy.sh
# Deployed das Wildcard-Zertifikat von Nginx Proxy Manager
# auf eine oder mehrere HPE iLO-Instanzen via Redfish API.
#
# Voraussetzungen:
#   - curl installiert
#   - config.env im gleichen Verzeichnis vorhanden
#   - NPM-Volume vom Host gemountet erreichbar
#
# Verwendung:
#   ./ilo-cert-deploy.sh            # alle Hosts aus config.env
#   ./ilo-cert-deploy.sh --dry-run  # nur Zertifikat prüfen, nichts deployen
#   ./ilo-cert-deploy.sh ilo-pve3.gustini-intern.de  # einzelner Host
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"

# --- Config laden ---
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "FEHLER: config.env nicht gefunden. Kopiere config.env.example nach config.env und passe die Werte an."
  exit 1
fi
source "$CONFIG_FILE"

# --- Logging ---
LOG_FILE="${LOG_FILE:-/var/log/ilo-cert-deploy.log}"
mkdir -p "$(dirname "$LOG_FILE")"

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE"
}

# --- Parameter auswerten ---
DRY_RUN=false
OVERRIDE_HOSTS=""

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    *) OVERRIDE_HOSTS="$arg" ;;
  esac
done

TARGET_HOSTS="${OVERRIDE_HOSTS:-$ILO_HOSTS}"

# --- Zertifikat prüfen ---
if [[ ! -f "$NPM_CERT_PATH" ]]; then
  log "FEHLER: Zertifikat nicht gefunden: $NPM_CERT_PATH"
  exit 1
fi
if [[ ! -f "$NPM_KEY_PATH" ]]; then
  log "FEHLER: Privater Schlüssel nicht gefunden: $NPM_KEY_PATH"
  exit 1
fi

# Ablaufdatum prüfen
EXPIRY=$(openssl x509 -enddate -noout -in "$NPM_CERT_PATH" | cut -d= -f2)
log "Zertifikat gültig bis: $EXPIRY"

# Zertifikat für JSON aufbereiten (Newlines als \n)
CERT_JSON=$(awk '{printf "%s\\n", $0}' "$NPM_CERT_PATH")
KEY_JSON=$(awk '{printf "%s\\n", $0}' "$NPM_KEY_PATH")

if $DRY_RUN; then
  log "DRY-RUN: Würde deployen auf: $TARGET_HOSTS"
  log "DRY-RUN: Kein API-Aufruf ausgeführt."
  exit 0
fi

# --- Deployment ---
ERRORS=0

for HOST in $TARGET_HOSTS; do
  log "Deploye Zertifikat auf $HOST ..."

  HTTP_STATUS=$(curl -k -s -o /tmp/ilo_response.json -w "%{http_code}" \
    -X POST \
    -u "$ILO_USER:$ILO_PASS" \
    -H "Content-Type: application/json" \
    -d "{\"Certificate\": \"$CERT_JSON\", \"PrivateKey\": \"$KEY_JSON\"}" \
    --connect-timeout 10 \
    --max-time 30 \
    "https://$HOST/redfish/v1/Managers/1/SecurityService/HttpsCert/Actions/HpeHttpsCert.ImportCertificate/")

  if [[ "$HTTP_STATUS" == "200" ]] || [[ "$HTTP_STATUS" == "204" ]]; then
    log "OK [$HTTP_STATUS]: $HOST — Zertifikat importiert. iLO startet Webservice neu (~30s)."
  else
    log "FEHLER [$HTTP_STATUS]: $HOST — $(cat /tmp/ilo_response.json)"
    ERRORS=$((ERRORS + 1))
  fi
done

# --- Zusammenfassung ---
if [[ $ERRORS -eq 0 ]]; then
  log "Deployment abgeschlossen. Alle Hosts erfolgreich aktualisiert."
else
  log "Deployment abgeschlossen mit $ERRORS Fehler(n). Siehe Log: $LOG_FILE"
  exit 1
fi
