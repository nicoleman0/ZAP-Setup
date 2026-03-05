The Docker-based approach works well in most environments, but native installation is sometimes preferable when:

- Docker hasn’t been approved by InfoSec (common in corporate environments)
- You want to avoid container networking complexity when scanning internal apps
- SonicWall DPI-SSL is intercepting traffic and you need direct control over the JVM trust store

> **Learning note:** DPI-SSL (Deep Packet Inspection - SSL) means your organisation’s firewall is performing a man-in-the-middle on HTTPS traffic so it can inspect it. ZAP also acts as a proxy/MITM when scanning. Two MITMs in a chain will cause SSL handshake failures unless you explicitly trust the firewall’s CA certificate. This is one of the most common “why isn’t ZAP working?” issues in corporate environments.

-----

## Prerequisites

Before starting, make sure you have these installed:

```bash
# envsubst (for environment variable substitution into YAML)
sudo apt install gettext-base

# Xvfb (virtual display — needed to run Firefox headlessly for the AJAX Spider)
sudo apt install xvfb

# Verify both are available
which envsubst
which Xvfb
```

> **Learning note:** ZAP’s AJAX Spider drives a real browser (Firefox) to crawl JavaScript-heavy apps. On a server or headless Linux system there’s no physical display, so you need Xvfb to create a virtual one. Without it, Firefox crashes immediately.

-----

## 1. Installation & Server Prep

**Install ZAP:**

```bash
# Option A: Snap (easiest — handles updates automatically)
sudo snap install zaproxy --classic

# Option B: Direct installer from https://www.zaproxy.org/download/
chmod +x ZAP_*_Linux.sh
./ZAP_*_Linux.sh
```

> **Snap vs direct install — what changes:** With Snap, the binary is `zaproxy` (at `/snap/bin/zaproxy`). With a direct install, it’s typically `zap.sh` inside the install directory (e.g. `/opt/zaproxy/zap.sh`). Throughout this guide, `zap.sh` is used as a placeholder — substitute the correct path for your install.

**Set up the workspace:**

```bash
# Clone this repo into ~/zap-scanner (the guide assumes this path)
git clone https://github.com/nicoleman0/ZAP-Setup ~/zap-scanner
cd ~/zap-scanner

mkdir -p wrk/reports
chmod -R u+rw wrk/
```

**Add credentials to `.env`:**

```bash
nano .env
```

```
ZAP_AUTH_USER=admin@example.com
ZAP_AUTH_PW=YourSecurePassword123
```

**Immediately add sensitive files to `.gitignore`:**

```bash
echo ".env" >> .gitignore
echo "wrk/scan-config-resolved.yaml" >> .gitignore
```

> **Why this matters:** `scan-config-resolved.yaml` will contain your plaintext credentials after variable substitution. If you accidentally commit it, those credentials are in your git history — even if you delete the file later. Add it to `.gitignore` now, before you forget.

-----

## 2. Configuration & Environment Variable Substitution

Native ZAP does not read `.env` files automatically. You must substitute variables into the YAML before passing it to ZAP.

**Always use scoped substitution:**

```bash
source .env
envsubst '${ZAP_AUTH_USER} ${ZAP_AUTH_PW}' < wrk/scan-config.yaml > wrk/scan-config-resolved.yaml
```

> **Why scoped?** Plain `envsubst` without arguments replaces *every* `$VARIABLE` pattern in the file. If your `scan-config.yaml` contains regex patterns with `$` (e.g. `loggedInRegex: \Qlogged in\E$`), they will be silently corrupted. Scoping it to `${ZAP_AUTH_USER}` and `${ZAP_AUTH_PW}` means only those two variables are touched.

**Config validation:**

There is no native ZAP flag that does a dry-run syntax check of an automation plan before running it. The closest approach is to test against a safe known-good target (e.g. `http://localhost` or OWASP’s own test app) first:

```bash
# Spin up WebGoat locally as a safe scan target for testing config
docker run -d -p 8080:8080 webgoat/goat-and-wolf
# Then run your scan against http://localhost:8080/WebGoat
```

-----

## 3. Handling SonicWall DPI-SSL

If ZAP fails with SSL handshake errors against your internal target, the SonicWall is intercepting the TLS connection and ZAP doesn’t trust the SonicWall’s certificate.

> **What’s actually happening:** Your org’s SonicWall terminates the HTTPS connection, inspects the traffic, then re-establishes a new HTTPS connection to the destination using its own CA. Browsers on corporate machines trust the SonicWall CA because it’s pushed via Group Policy. ZAP (running as a standalone Java app) has its own trust store and doesn’t know about the SonicWall CA unless you tell it.

**Quick fix (testing only — never production):**

```bash
zap.sh -config ssl.skip.verification=true -cmd -autorun wrk/scan-config-resolved.yaml
```

> Using `ssl.skip.verification=true` against a production system means ZAP will happily accept any certificate, including a real attacker’s. Use it only to confirm the SonicWall is the actual problem, then switch to the proper fix below.

**Proper fix — import the SonicWall CA cert:**

First, export the SonicWall CA certificate from your browser (Chrome: Settings > Security > Manage Certificates > Authorities, export as PEM) or ask your network team for the `.pem` file.

```bash
# Place the cert in the workspace
cp sonicwall-ca.pem ~/zap-scanner/wrk/

# Pass it to ZAP at runtime via JVM options
zap.sh -config certificate.use=true \
       -config certificate.pemFile=/home/$USER/zap-scanner/wrk/sonicwall-ca.pem \
       -cmd -autorun wrk/scan-config-resolved.yaml
```

Alternatively, import it through the ZAP GUI: **Tools > Options > Dynamic SSL Certificates > Import**.

> **Note:** The `configs: connection.ssl.caCert:` YAML key shown in some Docker-based guides does not apply here. Certificate trust for native ZAP is handled via JVM/ZAP startup options, not the automation plan YAML.

-----

## 4. Running and Monitoring

**Start Xvfb first** (required for AJAX Spider / Firefox):

```bash
Xvfb :99 &
export DISPLAY=:99
```

**Wrapper script** — handles `.env` sourcing, `envsubst`, Xvfb, and log capture in one step:

```bash
nano ~/zap-scanner/run-scan.sh
```

```bash
#!/bin/bash
set -euo pipefail

cd ~/zap-scanner

# Load credentials
source .env

# Substitute only the specific vars we want (safe for regex in YAML)
envsubst '${ZAP_AUTH_USER} ${ZAP_AUTH_PW}' < wrk/scan-config.yaml > wrk/scan-config-resolved.yaml

# Start virtual display for AJAX Spider / Firefox
Xvfb :99 &
XVFB_PID=$!
export DISPLAY=:99

# Run ZAP — log to timestamped file
zap.sh -cmd -autorun wrk/scan-config-resolved.yaml \
  2>&1 | tee wrk/reports/scan-$(date +%Y%m%d-%H%M%S).log

# Clean up Xvfb
kill $XVFB_PID
```

```bash
chmod +x ~/zap-scanner/run-scan.sh
```

**Run the scan:**

```bash
~/zap-scanner/run-scan.sh
```

**Monitor in a second terminal:**

```bash
tail -f ~/zap-scanner/wrk/reports/scan-*.log
```

**Resource monitoring:**

```bash
# Watch ZAP process memory and CPU
watch -n 2 'ps aux | grep -E "zap|java" | grep -v grep'

# More detailed view
top -p $(pgrep -f "zap.sh" | head -1)
```

> **Learning note:** ZAP runs inside a JVM (Java Virtual Machine). The process you’ll see in `ps`/`top` is actually a `java` process. ZAP is memory-heavy, especially during the AJAX Spider phase when it’s driving Firefox instances. If you see RAM climbing toward your system limit, reduce `numberOfBrowsers` to `1` in `scan-config.yaml`.

-----

## 5. Automated Maintenance (Cron)

ZAP session files (`.session`, `.session.data`, `.session.lck`, `.session.log`) can grow large quickly. The cleanup script prevents disk exhaustion.

```bash
crontab -e
```

Add:

```bash
# Delete ZAP session files older than 14 days — runs every Sunday at midnight
0 0 * * 0 find /home/$USER/zap-scanner/wrk -name "*.session*" -mtime +14 -delete

# Delete scan logs older than 30 days
0 1 * * 0 find /home/$USER/zap-scanner/wrk/reports -name "*.log" -mtime +30 -delete
```

> **Learning note:** Cron syntax is `minute hour day-of-month month day-of-week command`. `0 0 * * 0` means “at 00:00 on Sunday”. The `$USER` variable in crontab may not expand as expected in all environments — if the job doesn’t run, replace it with your literal username.

-----

## 6. Reading Your Results

ZAP reports are in `wrk/reports/`. Understanding the output:

- **High / Medium alerts** — things worth investigating. Not all are exploitable; ZAP reports heuristically.
- **False positives** — common with authentication-heavy apps. If ZAP loses its session mid-scan, it may flag login redirects as vulnerabilities.
- **Passive vs Active findings** — passive scan findings come from observing traffic (low risk of impact on the app); active scan findings come from ZAP actually sending attack payloads.

> **For your internship context:** When presenting findings to your team, always note whether an alert came from passive or active scanning, and whether you’ve manually verified it. Unverified scanner output handed to a dev team without triage creates noise and erodes trust in the security process.

-----

## Troubleshooting Guide

|Issue                                  |Root Cause                   |Fix                                                                                                  |
|---------------------------------------|-----------------------------|-----------------------------------------------------------------------------------------------------|
|**`zap.sh: command not found`**        |ZAP not on PATH              |Add install dir to `$PATH`, or use full path (e.g. `/opt/zaproxy/zap.sh`). Snap users: use `zaproxy`.|
|**SSL Handshake Failed**               |SonicWall DPI-SSL            |Import the SonicWall CA cert via `-config certificate.pemFile=` or ZAP GUI.                          |
|**Authentication Failed**              |Wrong `loggedInRegex`        |View source on the logged-in page; confirm your regex matches raw HTML, not rendered DOM.            |
|**Firefox Crashed / AJAX Spider fails**|No display / low RAM         |Run `Xvfb :99 &` and `export DISPLAY=:99` before ZAP. Set `numberOfBrowsers: 1`.                     |
|**Env vars not substituted**           |`.env` not sourced           |Use scoped `envsubst '${VAR1} ${VAR2}'` form inside the wrapper script.                              |
|**Permission denied on `reports/`**    |Directory not writable       |`chmod -R u+rw ~/zap-scanner/wrk`                                                                    |
|**Credentials in git history**         |Committed before `.gitignore`|Run `git filter-repo` or BFG Repo-Cleaner to purge. Don’t rotate creds as a substitute.              |
|**`$` in YAML regex got wiped**        |Unscoped `envsubst`          |Use `envsubst '${ZAP_AUTH_USER} ${ZAP_AUTH_PW}'` — never bare `envsubst`.                            |
|**`envsubst` not found**               |Not installed                |`sudo apt install gettext-base`                                                                      |
|**`Xvfb` not found**                   |Not installed                |`sudo apt install xvfb`                                                                              |

-----

## Reference Materials

- Official ZAP Automation Framework docs: https://www.zaproxy.org/docs/automate/automation-framework/
- ZAP Getting Started: https://www.zaproxy.org/getting-started/
- Original Docker-based guide: `guide.md` (in this repo)
- OWASP WebGoat (safe scan target for testing): https://github.com/WebGoat/WebGoat
