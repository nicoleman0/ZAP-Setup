## Background: What ZAP Actually Does

ZAP (Zed Attack Proxy) sits between your scanner and the target web application, sending requests and analysing responses for vulnerabilities. In automated mode (which is what this setup uses), it runs a spider to discover pages, then an active scanner to probe them for issues like XSS, SQL injection, broken authentication, and more.

> **Learning note:** ZAP is the open-source equivalent of Burp Suite Pro’s scanner. As an intern working in AppSec or DevSecOps, you’ll encounter both. ZAP is free, scriptable, and has a powerful Automation Framework (the YAML config you’ll be editing) — which makes it well-suited for repeatable, documented scanning pipelines like this one.

-----

## Prerequisites

Make sure the following are in place before starting:

- Docker and Docker Compose installed (`docker --version`, `docker compose version`)
- This repo cloned: `git clone https://github.com/nicoleman0/ZAP-Setup ~/zap-scanner`
- Access to the target application from the machine running ZAP

-----

## 1. Server Prep & Security

**Set up the workspace:**

```bash
mkdir -p ~/zap-scanner/wrk/reports
cd ~/zap-scanner
sudo chown -R 1000:1000 ~/zap-scanner/wrk
nano docker-compose.yml
nano wrk/scan-config.yaml
nano .env
```

> **Why UID 1000?** Docker containers don’t run as root by default (and shouldn’t). The ZAP image runs as a user with UID 1000 internally. When it tries to write reports to the mounted `./wrk` folder on your host, Linux checks whether UID 1000 has write permission on that directory. If your host user has a different UID (check with `id -u`), the container will get “Permission Denied” errors. `chown -R 1000:1000` makes UID 1000 the owner, regardless of what your host user is.

**In your `.env` file:**

```
ZAP_AUTH_USER=admin@example.com
ZAP_AUTH_PW=YourSecurePassword123
```

**Immediately protect it:**

```bash
# Prevent credentials from ever being committed
echo ".env" >> .gitignore
chmod 600 .env
```

> **Why `chmod 600`?** This makes the file readable only by you. On a shared server, other users could otherwise read your credentials. `600` = owner read/write, no access for anyone else.

> **If you accidentally commit `.env`:** Do not just delete the file and recommit. The credentials are now in your git history. You need to rotate the credentials AND use `git filter-repo` or BFG Repo-Cleaner to purge the history. Rotation without history purge is insufficient.

-----

## 2. Configuration Files

**`docker-compose.yml`** — the key settings and why they exist:

- `shm_size: '2gb'` — Firefox (used by the AJAX Spider) shares memory via `/dev/shm`. The Docker default is 64MB, which causes Firefox to crash mid-scan. 2GB prevents this.
- `user: zap` — runs the container as a non-root user (good practice).
- `ZAP_X_MX=8192m` — sets the JVM heap size to 8GB. ZAP is a Java app; without this it defaults to a much lower limit and will run out of memory on large scans.
- `memory: 12G` — hard Docker limit on container RAM. The 4GB gap above JVM heap gives the OS and Firefox room to breathe.

> **Learning note:** The `environment:` block in `docker-compose.yml` passes variables into the container. Docker Compose automatically reads your `.env` file and substitutes `${ZAP_AUTH_USER}` with its value before passing it in. This is why you don’t need `envsubst` like in the native setup — Docker Compose handles the substitution itself.

**`wrk/scan-config.yaml`** — uses `${ZAP_AUTH_USER}` and `${ZAP_AUTH_PW}` placeholders. These are resolved at runtime from the container’s environment variables (which Docker Compose populated from `.env`).

**Validate your config syntax** by doing a quick test run against a safe local target before pointing at production. There is no ZAP flag for dry-run validation — the `-verify` flag does not exist. Instead:

```bash
# Option A: Run against OWASP's deliberately vulnerable test app
docker run -d -p 8080:8080 --name webgoat webgoat/goat-and-wolf
# Then temporarily change your target URL in scan-config.yaml to http://host.docker.internal:8080/WebGoat
# Run the scan, confirm it completes without errors, then restore your real target

# Clean up
docker stop webgoat && docker rm webgoat
```

> **Learning note:** `host.docker.internal` is a special DNS name that resolves to your host machine’s IP from inside a Docker container. It’s how you point a containerised ZAP at a service running on your laptop. This only works on Docker Desktop (Mac/Windows) and newer Docker Engine versions on Linux.

-----

## 3. Handling SonicWall DPI-SSL

If ZAP fails with SSL handshake errors, the SonicWall firewall is almost certainly the cause.

> **What’s happening:** Your organisation’s SonicWall performs Deep Packet Inspection on HTTPS traffic. To do this, it acts as a man-in-the-middle — it terminates your TLS connection, decrypts the traffic, inspects it, then re-encrypts and forwards it using a certificate signed by the SonicWall’s own CA. Corporate machines trust this because the SonicWall CA is pushed via Group Policy. The ZAP Docker container has no idea that CA exists, so it rejects the certificate and the connection fails.

**Quick fix (initial testing only — never production):**

Add `-config ssl.skip.verification=true` to the `command:` in `docker-compose.yml`:

```yaml
command: >
  zap.sh -cmd
  -config ssl.skip.verification=true
  -autorun /zap/wrk/scan-config.yaml
```

> This disables all SSL verification. ZAP will accept any certificate, including a real attacker’s. Use it only to confirm the SonicWall is the actual problem, then switch to the proper fix.

**Proper fix — mount and trust the SonicWall CA cert:**

First get the cert: export it from Chrome (Settings > Privacy > Manage Certificates > Authorities, export as PEM), or ask your network team for the `.pem` file.

```bash
# Place the cert in your workspace
cp sonicwall-ca.pem ~/zap-scanner/wrk/
```

Update `docker-compose.yml` to pass it at startup:

```yaml
command: >
  zap.sh -cmd
  -config network.connection.tlsProtocols.tlsProtocol=TLSv1.2
  -config certificate.use=true
  -config certificate.pemFile=/zap/wrk/sonicwall-ca.pem
  -autorun /zap/wrk/scan-config.yaml
```

> **Note:** The `configs: - connection.ssl.caCert:` YAML key sometimes seen in other guides is **not a valid ZAP Automation Framework field**. Certificate trust must be set via `-config` flags at startup, not inside the automation plan YAML. The cert is available inside the container because `./wrk` is mounted to `/zap/wrk`.

-----

## 4. Running and Monitoring

**Start the scan (foreground — recommended for first runs):**

```bash
docker compose up
```

Running in foreground means you see logs directly and can `Ctrl+C` to stop. Once you’re confident it works:

```bash
# Background mode
docker compose up -d
# Then follow logs
docker logs -f zap-scanner
```

> **Why foreground first?** When something goes wrong on a first run (wrong path, bad YAML, auth failure), you want to see it immediately. Background mode makes debugging harder because the container may exit silently.

**Real-time resource monitoring:**

```bash
docker stats zap-scanner
```

This shows live CPU, RAM, and network I/O. Watch the `MEM USAGE` column during the AJAX Spider phase — Firefox instances are memory-heavy. If you’re approaching your 12GB limit, stop the scan and reduce `numberOfBrowsers` to `1` in `scan-config.yaml`.

**Check exit status after scan completes:**

```bash
docker inspect zap-scanner --format='{{.State.ExitCode}}'
```

ZAP exit codes: `0` = success, `1` = at least one FAIL alert, `2` = warnings only, `3` = other failure. A non-zero exit code doesn’t always mean the scan broke — it may mean ZAP found things.

-----

## 5. Reading Your Results

Reports land in `~/zap-scanner/wrk/reports/`. Understanding what you’re looking at:

- **High / Medium alerts** — worth investigating, but not all are exploitable. ZAP reports heuristically and will produce false positives.
- **Passive vs Active findings** — passive findings come from ZAP observing traffic (no attack payloads sent); active findings come from ZAP actually probing the app with attack strings. Active scanning is what can break things on fragile apps.
- **Confidence levels** — `High` confidence means ZAP is fairly sure; `Low` means it’s a guess based on indirect signals. Prioritise high-confidence findings.

> **For your internship context:** Don’t hand raw scanner output to developers. Triage first — confirm the finding is real, understand what it means, and write a plain-English explanation of the risk. Unverified, untriaged output from automated tools damages the credibility of the security function. Even one confirmed, well-explained finding is more useful than a 200-line report full of noise.

-----

## 6. Automated Maintenance (Cron)

ZAP session files grow large quickly and will fill disk if left unchecked.

```bash
crontab -e
```

Add:

```bash
# Delete ZAP session files older than 14 days — every Sunday at midnight
0 0 * * 0 find /home/$USER/zap-scanner/wrk -name "*.session*" -mtime +14 -delete

# Delete scan logs older than 30 days
0 1 * * 0 find /home/$USER/zap-scanner/wrk/reports -name "*.log" -mtime +30 -delete
```

> **Cron syntax reminder:** `minute hour day-of-month month day-of-week`. So `0 0 * * 0` = 00:00 on Sunday. If `$USER` doesn’t expand correctly in your crontab environment, replace it with your literal username.

-----

## Troubleshooting Guide

|Issue                                  |Root Cause                          |Fix                                                                                                                                                                         |
|---------------------------------------|------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|**Permission Denied on wrk/**          |UID 1000 mismatch                   |`sudo chown -R 1000:1000 ~/zap-scanner/wrk`                                                                                                                                 |
|**Container exits immediately**        |Bad YAML path or malformed config   |Run `docker compose up` (foreground) and read the error. Usually a wrong path in `scan-config.yaml` or missing file.                                                        |
|**SSL Handshake Failed**               |SonicWall DPI-SSL                   |Mount the SonicWall CA cert and pass `-config certificate.pemFile=` at startup.                                                                                             |
|**Authentication Failed**              |Wrong `loggedInRegex`               |View source on the logged-in page. Your regex must match the raw HTML response, not the rendered DOM.                                                                       |
|**Firefox Crashed / AJAX Spider fails**|`/dev/shm` too small                |Confirm `shm_size: '2gb'` is in `docker-compose.yml`.                                                                                                                       |
|**Out of memory mid-scan**             |Too many browser instances          |Set `numberOfBrowsers: 1` in `scan-config.yaml`.                                                                                                                            |
|**Can’t reach target app**             |Container network isolation         |If target is on your host: use `host.docker.internal`. If target is on the corporate network: ensure the Docker host has network access and no additional proxy is required.|
|**`${ZAP_AUTH_USER}` not substituted** |`.env` file missing or empty        |Confirm `.env` exists in the same directory as `docker-compose.yml` and contains the correct variable names.                                                                |
|**Credentials in git history**         |Committed `.env` before `.gitignore`|Rotate credentials immediately. Then purge history with `git filter-repo` or BFG Repo-Cleaner.                                                                              |

-----

## Reference Materials

- Official ZAP Automation Framework: https://www.zaproxy.org/docs/automate/automation-framework/
- ZAP Getting Started: https://www.zaproxy.org/getting-started/
- Docker Compose `.env` file docs: https://docs.docker.com/compose/environment-variables/env-file/
- OWASP WebGoat (safe scan target for testing): https://github.com/WebGoat/WebGoat
- Native installation guide: `native-guide.md` (in this repo)

