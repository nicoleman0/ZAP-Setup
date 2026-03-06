## Background: What ZAP Actually Does

ZAP (Zed Attack Proxy) sits between your scanner and the target web application, sending requests and analysing responses for vulnerabilities. In automated mode (which is what this setup uses), it runs a spider to discover pages, then an active scanner to probe them for issues like XSS, SQL injection, broken authentication, and more.

> **Learning note:** ZAP is the open-source equivalent of Burp Suite Pro’s scanner. As an intern working in AppSec or DevSecOps, you’ll encounter both. ZAP is free, scriptable, and has a powerful Automation Framework (the YAML config you’ll be editing) — which makes it well-suited for repeatable, documented scanning pipelines like this one.

-----

## Prerequisites

Make sure the following are in place before starting:

- Docker and Docker Compose installed (`docker --version`, `docker compose version`)
- The config files from this repo on your VM:
  ```bash
  git clone https://github.com/nicoleman0/ZAP-Setup ~/zap-scanner
  # or download and extract the zip from GitHub if git isn't available
  ```
  > **Note on version control:** If your organisation uses SVN, that doesn't apply here — you won't be checking this into org version control. You just need the files locally on the VM. Local git is optional but handy for tracking your own config changes.
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

> **What these credentials are:** `ZAP_AUTH_USER` and `ZAP_AUTH_PW` are the login credentials for the *web application you're scanning* — not for ZAP itself. ZAP uses them to authenticate against the target so it can reach pages that sit behind a login wall. Without them, ZAP can only scan publicly accessible pages.

> **If you don't have a target app yet:** Leave the placeholder values for now. ZAP will still run and scan unauthenticated content — it'll just skip or fail the auth step. Fill these in once a target is assigned.

> **When you do get a target — use a dedicated test account, not a real user account.** Ask the application owner or your team lead to create one. Reasons:
> - Active scanning sends attack payloads (SQL injection strings, XSS payloads, etc.) through the authenticated session. You don't want those associated with a real person's account.
> - ZAP may trigger account lockout policies if auth repeatedly fails during scanning.
> - If the app has per-user audit logging, ZAP's noise will pollute a real user's history.
> - A dedicated account can be scoped to only the permissions needed for the test.
>
> Ask for: a test account with the same access level as the users you're testing on behalf of — usually a standard user account, unless you've been specifically asked to test admin functionality.

**Immediately protect the `.env` file:**

```bash
chmod 600 .env
```

> **Why `chmod 600`?** This makes the file readable only by you. On a shared server, other users could otherwise read your credentials. `600` = owner read/write, no access for anyone else. This is the primary protection — it's more important than anything git-related.

If you're using local git to track config changes, also prevent `.env` from ever being committed:

```bash
echo ".env" >> .gitignore
```

> **If you accidentally commit `.env`:** Do not just delete the file and recommit. The credentials are in your git history. Rotate the credentials immediately, then use `git filter-repo` or BFG Repo-Cleaner to purge the history.

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

### Authentication Configuration *(complete this when you have a target)*

`scan-config.yaml` already has `${ZAP_AUTH_USER}` and `${ZAP_AUTH_PW}` placeholders, but those variable names alone aren’t enough. ZAP also needs to know *how* the login form works for your specific app. This is app-specific and can’t be filled in until you have a target assigned.

When you do, here’s what to gather:

**1. The login page URL**

The full URL of the page with the login form (e.g. `https://app.example.com/login`). This goes in `loginPageUrl` in `scan-config.yaml`.

**2. The form field names**

Open the login page in your browser, right-click the username input field, and choose Inspect. Find the `name` attribute on each `<input>` tag:

```html
<input type="text" name="email" ...>
<input type="password" name="password" ...>
```

These names are what you put in `loginRequestData` as the POST body parameters, e.g.:

```
email={%username%}&password={%password%}
```

ZAP substitutes `{%username%}` and `{%password%}` with your `.env` values at runtime.

**3. A `loggedInRegex`**

A regex matching something present in the raw HTML response *only* when the user is logged in. To find one:

- Log in to the app in your browser
- View Source (`Ctrl+U`) — not DevTools, which shows the rendered DOM
- Find something unique to the authenticated state: a display name, a "Log out" link, a nav item that only appears after login
- Write a simple regex matching it, e.g. `\QLog out\E` or `\Q/account/settings\E`

> **Why View Source and not DevTools?** ZAP checks the raw HTTP response body. Anything injected by JavaScript after page load won’t be there, so DevTools will mislead you.

**4. A `loggedOutRegex`** *(recommended)*

A regex matching something on the login/logged-out page, e.g. `\QForgot your password\E`. ZAP uses this to detect mid-scan session expiry so it can re-authenticate automatically rather than silently scanning as a logged-out user.

**Verify auth is working**

On your first run with real credentials, watch the foreground logs (`docker compose up`) for lines mentioning authentication. A failed auth usually shows up as ZAP repeatedly hitting the login page or a `loggedInIndicator not found` message. If auth fails, the scan will still complete but all findings will be from the unauthenticated perspective — which may miss the majority of the app’s attack surface.

-----

## 3. Handling SonicWall DPI-SSL

**For this VM setup, treat this section as required, not optional.**

If you had to install a company root CA certificate just to get the VM online and install Docker, you will definitely hit this problem with ZAP. Here’s why installing the cert on the OS wasn’t enough:

> **What’s happening:** Your organisation’s SonicWall performs Deep Packet Inspection (DPI-SSL) on HTTPS traffic. It acts as a man-in-the-middle — it terminates your TLS connection, inspects the traffic, then re-encrypts and forwards it using a certificate signed by the SonicWall’s own CA. When you installed the company root CA on the VM, you added it to the **Ubuntu OS trust store**. That’s what allows the OS, `curl`, `apt`, and Docker itself to work. But ZAP runs inside a Docker container as a **Java application**, and Java has its own separate trust store that is completely isolated from the OS. The container inherits nothing from the host. So ZAP will reject the SonicWall’s certificate and SSL handshakes will fail — even though the VM itself has no trouble reaching the internet.

**The good news:** You already have the cert. You installed it on the VM to get internet access. You don’t need to ask your network team for anything.

**Rename the cert if needed:**

If your cert is currently named after a hostname or something else unclear, rename it before proceeding:

```bash
sudo mv /usr/local/share/ca-certificates/old-name.crt /usr/local/share/ca-certificates/link-root-ca.crt
sudo update-ca-certificates
```

> `update-ca-certificates` must be re-run after any rename — it rebuilds the system trust bundle from that directory.

**Step 1 — Locate the cert on the VM:**

```bash
# It’s likely in /usr/local/share/ca-certificates/ — check with:
ls /usr/local/share/ca-certificates/

# If you’re not sure where you put it, find it:
sudo find /usr/local/share/ca-certificates /etc/ssl/certs -name "*.crt" -newer /etc/ssl/certs/ca-certificates.crt 2>/dev/null
```

The file will have a `.crt` extension. On Ubuntu, `.crt` files used with `update-ca-certificates` are PEM format (you can verify: `head -1 yourfile.crt` should show `-----BEGIN CERTIFICATE-----`). ZAP accepts PEM format directly.

**Step 2 — Copy it into your ZAP workspace:**

```bash
cp /usr/local/share/ca-certificates/link-root-ca.crt ~/zap-scanner/wrk/link-root-ca.crt
```

This works because `./wrk` is mounted into the container at `/zap/wrk`, so any file you put there is accessible inside the container.

**Step 3 — Update `docker-compose.yml` to pass it to ZAP at startup:**

```yaml
command: >
  zap.sh -cmd
  -config network.connection.tlsProtocols.tlsProtocol=TLSv1.2
  -config certificate.use=true
  -config certificate.pemFile=/zap/wrk/link-root-ca.crt
  -autorun /zap/wrk/scan-config.yaml
```

> **Note:** The `configs: - connection.ssl.caCert:` YAML key sometimes seen in other guides is **not a valid ZAP Automation Framework field**. Certificate trust must be set via `-config` flags at startup, not inside the automation plan YAML.

**If you’re not sure whether DPI-SSL is the issue (quick diagnostic):**

```yaml
command: >
  zap.sh -cmd
  -config ssl.skip.verification=true
  -autorun /zap/wrk/scan-config.yaml
```

> This disables all SSL verification — ZAP will accept any certificate. Use it only to confirm the SonicWall is the cause (if the scan works with this flag, it is). Switch to the cert-based fix immediately after. Never use `ssl.skip.verification=true` against a production target.

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

- [Official ZAP Automation Framework](https://www.zaproxy.org/docs/automate/automation-framework/)
- [ZAP Getting Started](https://www.zaproxy.org/getting-started/)
- [Docker Compose `.env` file docs](https://docs.docker.com/compose/environment-variables/env-file/)
- [OWASP WebGoat (safe scan target for testing)](https://github.com/WebGoat/WebGoat)
- Native installation guide: `native-guide.md` (in this repo)
