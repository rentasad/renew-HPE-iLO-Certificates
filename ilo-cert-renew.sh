#!/bin/bash
# ============================================================
# ilo-cert-renew.sh
#
# Automatisiertes SSL-Zertifikat-Renewal für HPE iLO via:
#   1. CSR-Generierung direkt auf der iLO (Redfish API)
#   2. Signierung via Let's Encrypt (acme.sh, DNS-01, Domain Offensive)
#   3. Import des signierten Zertifikats zurück in iLO (Redfish API)
#
# Der private Schlüssel verlässt dabei nie die iLO.
#
# Verwendung:
#   ./ilo-cert-renew.sh                          # alle Hosts, nur bei Bedarf
#   ./ilo-cert-renew.sh --force                  # alle Hosts, immer erneuern
#   ./ilo-cert-renew.sh ilo-pve3.gustini-intern.de        # einzelner Host
#   ./ilo-cert-renew.sh --dry-run                # nur prüfen, nichts tun
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "FEHLER: config.env nicht gefunden. Kopiere config.env.example nach config.env."
  exit 1
fi
source "$CONFIG_FILE"

LOG_FILE="${LOG_FILE:-/var/log/ilo-cert-renew.log}"
mkdir -p "$(dirname "$LOG_FILE")"

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE"
}

# --- Parameter ---
FORCE=false
DRY_RUN=false
OVERRIDE_HOST=""

for arg in "$@"; do
  case "$arg" in
    --force)   FORCE=true ;;
    --dry-run) DRY_RUN=true ;;
    *)         OVERRIDE_HOST="$arg" ;;
  esac
done

TARGET_HOSTS="${OVERRIDE_HOST:-$ILO_HOSTS}"

# --- Voraussetzungen prüfen ---
if [[ ! -x "$ACME_SH" ]]; then
  log "FEHLER: acme.sh nicht gefunden unter $ACME_SH"
  log "Installation: curl https://get.acme.sh | sh"
  exit 1
fi

if [[ -z "$DO_LETOKEN" ]] || [[ "$DO_LETOKEN" == "CHANGEME" ]]; then
  log "FEHLER: DO_LETOKEN nicht gesetzt in config.env"
  exit 1
fi

# --- Hilfsfunktionen ---

# Prüft ob Renewal nötig ist (<= RENEWAL_DAYS Restlaufzeit)
needs_renewal() {
  local host=$1
  local valid_until

  local cert_data
  cert_data=$(curl -k -s --connect-timeout 10 \
    -u "$ILO_USER:$ILO_PASS" \
    "https://$host/redfish/v1/Managers/1/SecurityService/HttpsCert/" \
    | python3 -c "
import sys, json
from datetime import datetime, timezone
d = json.load(sys.stdin)
info = d['X509CertificateInformation']
exp = info['ValidNotAfter']
issuer = info.get('Issuer', '')
dt = datetime.fromisoformat(exp.replace('Z','+00:00'))
now = datetime.now(timezone.utc)
days = (dt - now).days
print(f'{days}|{exp}|{issuer}')
" 2>/dev/null || echo "0|unbekannt|unbekannt")

  local days_left="${cert_data%%|*}"
  local rest="${cert_data#*|}"
  local expiry="${rest%%|*}"
  local issuer="${rest##*|}"

  log "  Aktuelles Zertifikat läuft ab: $expiry (${days_left} Tage verbleibend)"
  log "  Issuer: $issuer"

  # Renewal wenn: --force, Ablauf nahe, oder kein LE-Zertifikat
  if [[ "$FORCE" == "true" ]]; then
    log "  Grund: --force gesetzt"
    return 0
  fi
  if [[ "$days_left" -le "${RENEWAL_DAYS:-30}" ]]; then
    log "  Grund: Ablauf in ${days_left} Tagen (<= ${RENEWAL_DAYS:-30})"
    return 0
  fi
  if ! echo "$issuer" | grep -qi "let.s encrypt\|R3\|R10\|R11\|E5\|E6"; then
    log "  Grund: Kein Let's Encrypt Zertifikat — Erstausstellung erforderlich"
    return 0
  fi

  return 1  # Kein Renewal nötig
}

# Hilfsfunktion: CSR von iLO abrufen, CN zurückgeben
get_current_csr_cn() {
  local host=$1
  curl -k -s --connect-timeout 10 \
    -u "$ILO_USER:$ILO_PASS" \
    "https://$host/redfish/v1/Managers/1/SecurityService/HttpsCert/" \
    | python3 -c "
import sys, json, subprocess
d = json.load(sys.stdin)
csr = d.get('CertificateSigningRequest', '')
if not csr or 'BEGIN CERTIFICATE REQUEST' not in csr:
    print('')
    sys.exit(0)
result = subprocess.run(['openssl', 'req', '-text', '-noout'],
    input=csr.encode(), capture_output=True)
for line in result.stdout.decode().split('\n'):
    if 'Subject:' in line:
        for part in line.split(','):
            if 'CN' in part and '=' in part:
                print(part.split('=')[-1].strip())
                sys.exit(0)
print('')
" 2>/dev/null || echo ""
}

# Generiert neuen CSR auf der iLO (überspringt Generierung wenn CN bereits passt)
generate_csr() {
  local host=$1
  local cn=$2
  local csr_file=$3

  # Vorhandenen CSR prüfen — neugenerieren nur wenn CN nicht passt
  local existing_cn
  existing_cn=$(get_current_csr_cn "$host")

  if [[ "$existing_cn" == "$cn" ]]; then
    log "  Vorhandener CSR passt bereits (CN=$cn) — überspringe Neugenerierung."
  else
    log "  Generiere neuen CSR auf $host (CN=$cn)..."
    curl -k -s -X POST \
      --connect-timeout 10 \
      -u "$ILO_USER:$ILO_PASS" \
      -H "Content-Type: application/json" \
      -d "{
        \"CommonName\": \"$cn\",
        \"OrgName\": \"${ILO_ORG:-Gustini GmbH}\",
        \"OrgUnit\": \"${ILO_OU:-IT}\",
        \"City\": \"${ILO_CITY:-Leipzig}\",
        \"State\": \"${ILO_STATE:-Sachsen}\",
        \"Country\": \"${ILO_COUNTRY:-DE}\"
      }" \
      "https://$host/redfish/v1/Managers/1/SecurityService/HttpsCert/Actions/HpeHttpsCert.GenerateCSR/" > /dev/null

    # Polling bis CSR bereit (max. 30 Sekunden)
    log "  Warte auf CSR-Generierung..."
    local attempts=0
    while [[ $attempts -lt 15 ]]; do
      sleep 2
      local csr
      csr=$(curl -k -s --connect-timeout 10 \
        -u "$ILO_USER:$ILO_PASS" \
        "https://$host/redfish/v1/Managers/1/SecurityService/HttpsCert/" \
        | python3 -c "
import sys, json
d = json.load(sys.stdin)
csr = d.get('CertificateSigningRequest', '')
print(csr if 'BEGIN CERTIFICATE REQUEST' in csr else '')
" 2>/dev/null || echo "")
      if [[ -n "$csr" ]]; then
        log "  CSR erfolgreich generiert."
        break
      fi
      attempts=$((attempts + 1))
    done

    if [[ $attempts -ge 15 ]]; then
      log "FEHLER: CSR-Generierung Timeout nach 30 Sekunden"
      return 1
    fi
  fi

  # CSR in Datei speichern
  curl -k -s --connect-timeout 10 \
    -u "$ILO_USER:$ILO_PASS" \
    "https://$host/redfish/v1/Managers/1/SecurityService/HttpsCert/" \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('CertificateSigningRequest', ''))
" > "$csr_file"

  if [[ ! -s "$csr_file" ]] || ! grep -q "BEGIN CERTIFICATE REQUEST" "$csr_file"; then
    log "FEHLER: CSR-Datei ungültig"
    return 1
  fi
}

# Signiert CSR via acme.sh (Let's Encrypt, DNS-01, Domain Offensive)
sign_csr() {
  local csr_file=$1
  local domain=$2
  local cert_dir="$HOME/.acme.sh/$domain"

  log "  Signiere CSR via acme.sh (DNS-01, Domain Offensive)..."

  export DO_LETOKEN

  "$ACME_SH" --signcsr \
    --csr "$csr_file" \
    --dns dns_doapi \
    --server letsencrypt \
    2>&1 | tee -a "$LOG_FILE"

  # acme.sh legt Cert unter ~/.acme.sh/<domain>/ ab
  if [[ ! -f "$cert_dir/fullchain.cer" ]]; then
    log "FEHLER: Signiertes Zertifikat nicht gefunden unter $cert_dir/fullchain.cer"
    return 1
  fi

  log "  Zertifikat signiert: $cert_dir/fullchain.cer"
}

# Importiert signiertes Zertifikat in iLO
import_cert() {
  local host=$1
  local cert_file=$2

  local cert_json
  cert_json=$(awk '{printf "%s\\n", $0}' "$cert_file")

  local http_code
  http_code=$(curl -k -s \
    -o /tmp/ilo_import_response.json \
    -w "%{http_code}" \
    -X POST \
    --connect-timeout 10 \
    --max-time 30 \
    -u "$ILO_USER:$ILO_PASS" \
    -H "Content-Type: application/json" \
    -d "{\"Certificate\": \"$cert_json\"}" \
    "https://$host/redfish/v1/Managers/1/SecurityService/HttpsCert/Actions/HpeHttpsCert.ImportCertificate/")

  if [[ "$http_code" == "200" ]] || [[ "$http_code" == "204" ]]; then
    log "  OK [$http_code]: Zertifikat importiert. iLO startet Webservice neu (~30s)."
    return 0
  else
    log "  FEHLER [$http_code]: $(cat /tmp/ilo_import_response.json)"
    return 1
  fi
}

# --- Hauptprogramm ---
ERRORS=0

log "========================================"
log "iLO Cert Renew — Start"
log "Hosts: $TARGET_HOSTS"
$FORCE   && log "Modus: --force (immer erneuern)"
$DRY_RUN && log "Modus: --dry-run (kein API-Aufruf)"
log "========================================"

for HOST in $TARGET_HOSTS; do
  log "--- $HOST ---"

  if ! needs_renewal "$HOST"; then
    log "  Kein Renewal nötig — überspringe."
    continue
  fi

  if $DRY_RUN; then
    log "  DRY-RUN: Würde CSR generieren, signieren und importieren."
    continue
  fi

  CSR_FILE="/tmp/ilo-${HOST}.csr"
  CERT_FILE="$HOME/.acme.sh/${HOST}/fullchain.cer"

  # 1. CSR generieren
  if ! generate_csr "$HOST" "$HOST" "$CSR_FILE"; then
    ERRORS=$((ERRORS + 1))
    continue
  fi

  # 2. CSR signieren
  if ! sign_csr "$CSR_FILE" "$HOST"; then
    ERRORS=$((ERRORS + 1))
    rm -f "$CSR_FILE"
    continue
  fi

  # 3. Zertifikat importieren
  if ! import_cert "$HOST" "$CERT_FILE"; then
    ERRORS=$((ERRORS + 1))
  fi

  rm -f "$CSR_FILE"
done

log "========================================"
if [[ $ERRORS -eq 0 ]]; then
  log "Abgeschlossen — alle Hosts erfolgreich."
else
  log "Abgeschlossen mit $ERRORS Fehler(n). Siehe: $LOG_FILE"
  exit 1
fi
