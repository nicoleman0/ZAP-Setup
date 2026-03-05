### 1. Installation & Server Prep

**Install ZAP:**

```bash
# Option A: Snap (recommended for ease of updates)
sudo snap install zaproxy --classic

# Option B: Direct download
# Download the Linux installer from https://www.zaproxy.org/download/
chmod +x ZAP_*_Linux.sh
./ZAP_*_Linux.sh
```

**Set Up Workspace:**

```bash
mkdir -p ~/zap-scanner/wrk/reports
cd ~/zap-scanner
```

No UID ownership issues apply here since ZAP runs as your own user. However, ensure the `wrk/` directory is writable:

```bash
chmod -R u+rw ~/zap-scanner/wrk
```

**Secret Management:** Create a `.env` file to keep credentials out of your YAML.

```bash
nano .env
# Add these lines:
ZAP_AUTH_USER=admin@example.com
ZAP_AUTH_PW=YourSecurePassword123
```

Source the `.env` before running ZAP, or use a wrapper script (see Section 4).

-----

### 2. Configuration Files

**`wrk/scan-config.yaml`:** Use environment variable placeholders for credentials. These must be resolved before passing to ZAP — native ZAP does not automatically read from `.env` files.

**Pre-run substitution:**

```bash
# Substitute env vars into config before running
source .env
envsubst < wrk/scan-config.yaml > wrk/scan-config-resolved.yaml
```

**Validation:** Run a syntax check before the full scan:

```bash
zap.sh -cmd -autorun ~/zap-scanner/wrk/scan-config-resolved.yaml -verify
```

If ZAP was installed via Snap, the binary path is typically:

```bash
/snap/bin/zaproxy -cmd -autorun ~/zap-scanner/wrk/scan-config-resolved.yaml -verify
```

-----

### 3. Handling SonicWall DPI-SSL

If ZAP cannot connect to your target, the SonicWall is likely intercepting TLS and ZAP doesn’t trust the SonicWall’s certificate.

- **The Quick Fix:** Add `-config ssl.skip.verification=true` to your ZAP command (use only for initial testing).
- **The “Pro” Fix:** Export your SonicWall CA cert as a `.cer` or `.pem` file, place it in `~/zap-scanner/wrk/`, then tell ZAP to trust it via your YAML config:

```yaml
configs:
  - connection.ssl.caCert: /home/<your-user>/zap-scanner/wrk/sonicwall-ca.pem
```

Alternatively, import the cert into ZAP’s trust store via the GUI under **Tools > Options > Dynamic SSL Certificates**, or pass it at runtime:

```bash
zap.sh -config ssl.caCertFile=/home/<your-user>/zap-scanner/wrk/sonicwall-ca.pem \
       -cmd -autorun ~/zap-scanner/wrk/scan-config-resolved.yaml
```

-----

### 4. Running and Monitoring

**Wrapper script** (handles `.env` sourcing and log capture):

```bash
nano ~/zap-scanner/run-scan.sh
```

```bash
#!/bin/bash
set -euo pipefail
cd ~/zap-scanner
source .env
envsubst < wrk/scan-config.yaml > wrk/scan-config-resolved.yaml
zap.sh -cmd -autorun wrk/scan-config-resolved.yaml 2>&1 | tee wrk/reports/scan-$(date +%Y%m%d-%H%M%S).log
```

```bash
chmod +x ~/zap-scanner/run-scan.sh
```

**Start scan:**

```bash
~/zap-scanner/run-scan.sh
```

**Follow progress in a separate terminal:**

```bash
tail -f ~/zap-scanner/wrk/reports/scan-*.log
```

**Real-time resource monitoring:**

```bash
# Watch ZAP's memory and CPU usage
watch -n 2 'ps aux | grep zap'
# Or more detail:
top -p $(pgrep -f "zap.sh")
```

> Watch RAM during the AJAX Spider phase. Native ZAP does not have a `shm_size` constraint like Docker, but Firefox (used by the AJAX Spider) is still memory-hungry. If RAM is tight, reduce `numberOfBrowsers` to 1 in your scan config.

-----

### 5. Automated Maintenance (Cron)

The cleanup script prevents disk exhaustion from large ZAP session files.

```bash
# Edit crontab
crontab -e

# Add: Run every Sunday at midnight
0 0 * * 0 find /home/$USER/zap-scanner/wrk -name "*.session" -mtime +14 -delete
```

Also consider rotating logs:

```bash
# Add to crontab: delete scan logs older than 30 days
0 1 * * 0 find /home/$USER/zap-scanner/wrk/reports -name "*.log" -mtime +30 -delete
```

-----

### Troubleshooting Guide

|Issue                                  |Root Cause                         |Fix                                                                                       |
|---------------------------------------|-----------------------------------|------------------------------------------------------------------------------------------|
|**`zap.sh: command not found`**        |ZAP not on PATH                    |Add ZAP install dir to `$PATH`, or use the full binary path (e.g., `/opt/zaproxy/zap.sh`).|
|**SSL Handshake Failed**               |SonicWall DPI-SSL                  |Import the SonicWall CA cert or use `-config ssl.skip.verification=true`.                 |
|**Authentication Failed**              |Wrong `loggedInRegex`              |Check “View Source” of the target app to confirm the regex matches raw HTML.              |
|**Firefox Crashed / AJAX Spider fails**|Insufficient RAM or missing display|Ensure `numberOfBrowsers` is low (1–2); run with `DISPLAY=:99` if headless via Xvfb.      |
|**Env vars not substituted**           |`.env` not sourced                 |Always run `source .env && envsubst` before launching ZAP, or use the wrapper script.     |
|**Permission Denied on reports/**      |Directory not writable             |Run `chmod -R u+rw ~/zap-scanner/wrk`.                                                    |
