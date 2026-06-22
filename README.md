# iloCertDeploy

> Automated SSL certificate renewal for HPE iLO via Let's Encrypt · Automatisiertes SSL-Zertifikat-Renewal für HPE iLO via Let's Encrypt

---

## 🇬🇧 English

### What it does

HPE iLO ships with a self-signed default certificate ("Default Issuer — Do not trust") which triggers a security warning in the iLO Security Dashboard. This project automates replacing it with a trusted Let's Encrypt certificate.

Because iLO's Redfish API does not allow importing an external private key, the script uses the **CSR workflow**:

```
iLO generates key pair + CSR
  → acme.sh signs CSR (DNS-01, your DNS provider)
    → Signed certificate is imported back into iLO via Redfish API
      → iLO restarts its web service (~30s)
```

The private key never leaves the iLO — more secure than importing a shared wildcard certificate.

### Requirements

- HPE ProLiant server with iLO 5 or iLO 6
- Linux host with `curl`, `openssl`, `python3`
- [acme.sh](https://github.com/acmesh-official/acme.sh) installed
- A DNS provider supported by acme.sh ([full list](https://github.com/acmesh-official/acme.sh/wiki/dnsapi))
- DNS record pointing to your iLO (e.g. `ilo-server1.example.com`)
- A dedicated service account in iLO with minimal permissions (see below)

### Setup

#### 1. Install acme.sh

```bash
curl https://get.acme.sh | sh -s email=admin@example.com
source ~/.bashrc
```

#### 2. Configure

```bash
cp config.env.example config.env
chmod 600 config.env
nano config.env
```

Key settings in `config.env`:

| Variable | Description |
|---|---|
| `ILO_HOSTS` | Space-separated list of iLO hostnames |
| `ILO_USER` | iLO service account username |
| `ILO_PASS` | iLO service account password |
| `ACME_SH` | Path to acme.sh (default: `~/.acme.sh/acme.sh`) |
| `DO_LETOKEN` | DNS provider API token (variable name depends on your provider) |
| `RENEWAL_DAYS` | Renew if fewer than N days remaining (default: 30) |

> **Note on DNS provider variable:** The variable name for your API token depends on your DNS provider's acme.sh plugin. Check the [acme.sh DNS API docs](https://github.com/acmesh-official/acme.sh/wiki/dnsapi) for the correct variable and plugin name (e.g. `dns_cf` for Cloudflare, `dns_doapi` for Domain Offensive).

#### 3. Prepare iLO

**Set the iLO hostname:**  
Network → iLO Dedicated Network Port → General → iLO Subsystem Name  
The hostname must match the DNS record (e.g. `ilo-server1` with domain `example.com` → FQDN `ilo-server1.example.com`)

**Create a dedicated service account with minimal permissions:**  
User Administration → New → Role: Custom

| Privilege | Required |
|---|---|
| Login | ✅ Yes |
| Configure iLO Settings | ✅ Yes |
| Remote Console | ❌ No |
| Virtual Power and Reset | ❌ No |
| Virtual Media | ❌ No |
| Host BIOS | ❌ No |
| Administer User Accounts | ❌ No |
| Host NIC | ❌ No |
| Host Storage | ❌ No |
| Recovery Set | ❌ No |

Enable **Service Account** checkbox. These two privileges are sufficient for `GenerateCSR` and `ImportCertificate` via the Redfish API.

#### 4. Run

```bash
chmod +x ilo-cert-renew.sh

# Dry run — checks only, no API calls
./ilo-cert-renew.sh --dry-run

# First run — force renewal regardless of expiry
./ilo-cert-renew.sh --force

# Single host
./ilo-cert-renew.sh --force ilo-server1.example.com
```

#### 5. Schedule (monthly cron)

```bash
crontab -e
```
```cron
0 3 1 * * /opt/iloCertDeploy/ilo-cert-renew.sh >> /var/log/ilo-cert-renew.log 2>&1
```

### Adding a new server

1. Create DNS record: `ilo-serverX.example.com → <iLO IP>`
2. Set iLO hostname in iLO network settings
3. Create service account in iLO
4. Add hostname to `ILO_HOSTS` in `config.env`
5. Run: `./ilo-cert-renew.sh --force ilo-serverX.example.com`

### Usage

```bash
./ilo-cert-renew.sh                          # all hosts, only if renewal needed
./ilo-cert-renew.sh --force                  # all hosts, always renew
./ilo-cert-renew.sh --dry-run                # check only, no changes
./ilo-cert-renew.sh ilo-server1.example.com  # single host
./ilo-cert-renew.sh --force ilo-server1.example.com
```

### Security notes

- `config.env` contains credentials — it is excluded from git via `.gitignore`. **Never commit it.**
- Each iLO gets its own certificate and key pair. The private key is generated on and stays on the iLO.
- Let's Encrypt certificates expire after 90 days. The monthly cron job renews them automatically when fewer than `RENEWAL_DAYS` days remain.
- On first run for a new server, the script detects the HPE default issuer and forces renewal automatically — no `--force` flag needed.

---

## 🇩🇪 Deutsch

### Was es tut

HPE iLO wird ab Werk mit einem selbstsignierten Zertifikat ausgeliefert ("Default Issuer — Do not trust"), das im iLO Security Dashboard als Risiko gemeldet wird. Dieses Projekt automatisiert den Austausch gegen ein vertrauenswürdiges Let's Encrypt Zertifikat.

Da die Redfish API von iLO keinen Import eines externen Private Keys erlaubt, verwendet das Script den **CSR-Workflow**:

```
iLO generiert Key-Pair + CSR
  → acme.sh signiert CSR (DNS-01, DNS-Provider)
    → Signiertes Zertifikat wird via Redfish API in iLO importiert
      → iLO startet Webservice neu (~30s)
```

Der private Schlüssel verlässt dabei nie die iLO.

### Voraussetzungen

- HPE ProLiant Server mit iLO 5 oder iLO 6
- Linux-Host mit `curl`, `openssl`, `python3`
- [acme.sh](https://github.com/acmesh-official/acme.sh) installiert
- Ein von acme.sh unterstützter DNS-Provider ([vollständige Liste](https://github.com/acmesh-official/acme.sh/wiki/dnsapi))
- DNS-Eintrag für die iLO (z.B. `ilo-server1.example.com`)
- Dedizierter Service-Account in iLO mit minimalen Berechtigungen (siehe unten)

### Setup

#### 1. acme.sh installieren

```bash
curl https://get.acme.sh | sh -s email=admin@example.com
source ~/.bashrc
```

#### 2. Konfigurieren

```bash
cp config.env.example config.env
chmod 600 config.env
nano config.env
```

Wichtige Einstellungen in `config.env`:

| Variable | Beschreibung |
|---|---|
| `ILO_HOSTS` | Leerzeichen-getrennte iLO-Hostnamen |
| `ILO_USER` | iLO Service-Account Benutzername |
| `ILO_PASS` | iLO Service-Account Passwort |
| `ACME_SH` | Pfad zu acme.sh (Standard: `~/.acme.sh/acme.sh`) |
| `DO_LETOKEN` | API-Token des DNS-Providers (Variablenname abhängig vom Provider) |
| `RENEWAL_DAYS` | Renewal wenn weniger als N Tage Restlaufzeit (Standard: 30) |

> **Hinweis zum DNS-Provider:** Variablenname und Plugin-Name hängen vom DNS-Provider ab. Für Domain Offensive z.B. `DO_LETOKEN` und Plugin `dns_doapi`. Siehe [acme.sh DNS API Dokumentation](https://github.com/acmesh-official/acme.sh/wiki/dnsapi).

#### 3. iLO vorbereiten

**iLO-Hostname setzen:**  
Network → iLO Dedicated Network Port → General → iLO Subsystem Name  
Der Hostname muss dem DNS-Eintrag entsprechen (z.B. `ilo-server1` mit Domain `example.com` → FQDN `ilo-server1.example.com`)

**Dedizierten Service-Account mit minimalen Berechtigungen anlegen:**  
User Administration → New → Role: Custom

| Berechtigung | Erforderlich |
|---|---|
| Login | ✅ Ja |
| Configure iLO Settings | ✅ Ja |
| Remote Console | ❌ Nein |
| Virtual Power and Reset | ❌ Nein |
| Virtual Media | ❌ Nein |
| Host BIOS | ❌ Nein |
| Administer User Accounts | ❌ Nein |
| Host NIC | ❌ Nein |
| Host Storage | ❌ Nein |
| Recovery Set | ❌ Nein |

**Service Account**-Checkbox aktivieren. Diese zwei Berechtigungen genügen für `GenerateCSR` und `ImportCertificate` via Redfish API.

#### 4. Ausführen

```bash
chmod +x ilo-cert-renew.sh

# Dry-Run — nur prüfen, kein API-Aufruf
./ilo-cert-renew.sh --dry-run

# Erster Lauf — Renewal erzwingen
./ilo-cert-renew.sh --force

# Einzelner Host
./ilo-cert-renew.sh --force ilo-server1.example.com
```

#### 5. Cronjob einrichten

```bash
crontab -e
```
```cron
0 3 1 * * /opt/iloCertDeploy/ilo-cert-renew.sh >> /var/log/ilo-cert-renew.log 2>&1
```

### Neuen Server hinzufügen

1. DNS-Eintrag anlegen: `ilo-serverX.example.com → <iLO-IP>`
2. iLO-Hostname in iLO Network Settings setzen
3. Service-Account in iLO anlegen
4. Hostname in `config.env` zu `ILO_HOSTS` hinzufügen
5. Ausführen: `./ilo-cert-renew.sh --force ilo-serverX.example.com`

---

## Tested on

| Hardware | iLO Version | OS |
|---|---|---|
| HPE ProLiant DL385 Gen11 | iLO 6 (1.76) | Debian 12 (Proxmox VE 9.2) |

Contributions and test reports for other hardware/iLO versions are welcome.

---

## License

MIT

---

<sub>This project was developed with the assistance of [Claude Sonnet 4.6](https://www.anthropic.com/claude) (Anthropic) in an interactive session covering HPE iLO security hardening, Redfish API exploration, Let's Encrypt automation, and iterative script debugging.</sub>
