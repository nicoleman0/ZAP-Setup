# ZAP Implementation Checklist

### 1. Server Prep & Security

Instead of `chmod 777` (which is a security risk in professional environments), we will use specific ownership so the ZAP container user can write to your host folder.

* **Set Up Workspace:**
```bash
mkdir -p ~/zap-scanner/wrk/reports
cd ~/zap-scanner
# Grant ownership to UID 1000 (ZAP's internal user)
sudo chown -R 1000:1000 ~/zap-scanner/wrk

```


* **Secret Management:** Create a `.env` file to keep passwords out of your YAML.
```bash
nano .env
# Add these lines:
ZAP_AUTH_USER=admin@example.com
ZAP_AUTH_PW=YourSecurePassword123

```



### 2. Configuration Files

* **`docker-compose.yml`:** Ensure `shm_size: '2gb'` is present to prevent AJAX Spider crashes.
* **`wrk/scan-config.yaml`:** Use `${ZAP_AUTH_USER}` placeholders to pull from your `.env`.
* **Validation:** Run a syntax check before the full scan:
```bash
docker run --rm -v $(pwd)/wrk:/zap/wrk:rw zaproxy/zap-stable zap.sh -cmd -autorun /zap/wrk/scan-config.yaml -verify

```



### 3. Handling SonicWall DPI-SSL

If ZAP cannot connect to your target app, it's likely the SonicWall is intercepting the traffic and ZAP doesn't trust the SonicWall's certificate.

* **The Quick Fix:** Add `-config ssl.skip.verification=true` to your docker command (use only for initial testing).
* **The "Pro" Fix:** Export your SonicWall CA cert as a `.cer` or `.pem` file, place it in `~/zap-scanner/wrk/`, and tell ZAP to use it via the `configs` section in your YAML:
```yaml
# Add to the 'parameters' or 'configs' section of your scan-config.yaml
configs:
  - connection.ssl.caCert: /zap/wrk/sonicwall-ca.pem

```



### 4. Running and Monitoring

* **Start:** `docker-compose up -d` (runs in background).
* **Follow Progress:** `docker logs -f zap-scanner`
* **Real-time Resource Monitoring:**
```bash
docker stats zap-scanner

```


*Watch the RAM during the AJAX Spider phase; if it nears 12GB, your 8-core CPU will handle the thread load, but you might need to drop `numberOfBrowsers` to 1.*

### 5. Automated Maintenance (Cron)

The cleanup script ensures the server doesn't run out of disk space from large session files.

```bash
# Edit crontab
crontab -e

# Add: Run every Sunday at midnight
0 0 * * 0 find /home/$USER/zap-scanner/wrk -name "*.session" -mtime +14 -delete

```

---

### Troubleshooting Guide

| Issue | Root Cause | Fix |
| --- | --- | --- |
| **Permission Denied** | UID 1000 mismatch | Run `sudo chown -R 1000:1000 ~/zap-scanner/wrk`. |
| **SSL Handshake Failed** | SonicWall DPI-SSL | Import the SonicWall CA cert or use `ssl.skip.verification`. |
| **Authentication Failed** | Wrong `loggedInRegex` | Check "View Source" of the app to ensure the regex matches raw HTML. |
| **Firefox Crashed** | `/dev/shm` too small | Ensure `shm_size: '2gb'` is in your docker-compose file. |
