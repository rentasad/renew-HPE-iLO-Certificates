# iloCertDeploy

Automatisiertes SSL-Zertifikat-Renewal für **HPE iLO** via Let's Encrypt.

## Funktionsprinzip

HPE iLO akzeptiert über die Redfish API keine externen Private Keys. Das Script nutzt daher den CSR-Workflow: iLO generiert selbst ein Key-Pair, der CSR wird von Let's Encrypt signiert, das Zertifikat zurückimportiert. Der private Schlüssel verlässt dabei nie die iLO.

```
iLO generiert Key-Pair + CSR
  → acme.sh signiert CSR (DNS-01, Domain Offensive)
    → Signiertes Cert wird via Redfish importiert
      → iLO startet Webservice neu (~30s)
```

## Infrastruktur

| Komponente | Host | Beschreibung |
|---|---|---|
| ilo-cert-renew.sh | docker-vw | Läuft als Cronjob |
| acme.sh | docker-vw | ACME-Client für DNS-01 Challenge |
| DNS | Domain Offensive | DNS-01 Challenge via API-Token |
| iLO-Ziele | ilo-pveX.gustini-intern.de | HPE ProLiant Server im Verwaltungsnetz |

## Voraussetzungen

- `curl`, `openssl`, `python3` auf dem Host installiert
- acme.sh installiert (siehe Setup)
- DNS-Einträge für alle iLO-Hosts vorhanden
- iLO-Hostname in iLO gesetzt (Network → iLO Hostname → z.B. `ilo-pve3`)
- Service-Account `gustini` in iLO unter User Administration → Service

## Setup

### 1. acme.sh installieren

```bash
curl https://get.acme.sh | sh -s email=admin@gustini.de
source ~/.bashrc
```

Der `-s email=...` Parameter ist zwingend erforderlich — ohne ihn schlägt die Installation fehl.
acme.sh registriert damit gleichzeitig den Let's Encrypt Account.

### 3. Config anlegen

```bash
cp config.env.example config.env
chmod 600 config.env
nano config.env   # DO_LETOKEN, ILO_PASS und ILO_HOSTS eintragen
```

### 4. Script ausführbar machen

```bash
chmod +x ilo-cert-renew.sh
```

### 5. DNS-Eintrag und iLO-Hostname setzen

Für jeden Server:
- DNS-Eintrag anlegen: `ilo-pveX.gustini-intern.de → <iLO-IP>`
- In iLO: Network → iLO Dedicated Network Port → iLO Hostname → `ilo-pveX`

### 6. Testlauf

```bash
# Nur prüfen, kein API-Aufruf
./ilo-cert-renew.sh --dry-run

# Einzelnen Host testen (erzwingt Renewal)
./ilo-cert-renew.sh --force ilo-pve3.gustini-intern.de
```

### 7. Cronjob einrichten

```bash
crontab -e
```

```cron
# iLO Zertifikate monatlich prüfen und bei Bedarf erneuern (LE = 90 Tage)
0 3 1 * * /opt/iloCertDeploy/ilo-cert-renew.sh >> /var/log/ilo-cert-renew.log 2>&1
```

## Verwendung

```bash
# Alle Hosts — nur bei Bedarf (< RENEWAL_DAYS Restlaufzeit)
./ilo-cert-renew.sh

# Alle Hosts — immer erneuern
./ilo-cert-renew.sh --force

# Einzelner Host
./ilo-cert-renew.sh ilo-pve3.gustini-intern.de

# Einzelner Host, immer erneuern
./ilo-cert-renew.sh --force ilo-pve3.gustini-intern.de

# Nur prüfen, nichts tun
./ilo-cert-renew.sh --dry-run
```

## Neuen Server hinzufügen

1. DNS-Eintrag anlegen: `ilo-pveX.gustini-intern.de → <iLO-IP>`
2. In iLO Hostname setzen: Network → iLO Hostname → `ilo-pveX`
3. Service-Account `gustini` in iLO anlegen (falls nicht per Template)
4. In `config.env`: neuen Host zu `ILO_HOSTS` hinzufügen
5. Erstmalig ausführen: `./ilo-cert-renew.sh --force ilo-pveX.gustini-intern.de`

## Hinweise

- Nach dem Cert-Import startet iLO den Webservice neu (~30 Sekunden)
- `config.env` enthält Passwörter — nicht in git eincheckt (`.gitignore`)
- Let's Encrypt Zertifikate laufen nach 90 Tagen ab — Renewal bei `RENEWAL_DAYS=30`
- acme.sh legt Zertifikate ab unter `~/.acme.sh/<hostname>/`
- Jede iLO bekommt ein eigenes Zertifikat (eigener Key, bleibt auf iLO)
