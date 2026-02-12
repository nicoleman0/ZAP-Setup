## ZAP Implementation Checklist

### 1. Server Prep (Post-Handover)

Once the infra team gives you the Ubuntu 24.04 credentials:

* **Install Docker:** This is the easiest way to manage the dependencies you listed (Java, ZAP binaries, etc.).
```bash
sudo apt update && sudo apt install docker.io docker-compose -y
sudo usermod -aG docker $USER  # Log out and back in after this

```


* **Directory Structure:** Create your workspace to match your YAML.
```bash
mkdir -p ~/zap-scanner/wrk/reports
cd ~/zap-scanner

```


* **Permissions:** Ensure the ZAP user (UID 1000 in the docker image) can write to your folders.
```bash
chmod -R 777 ~/zap-scanner/wrk

```



### 2. Configuration Files

Place your two files in the `~/zap-scanner` directory.

* **File 1: `docker-compose.yaml**` (Use the snippet you provided).
* **File 2: `wrk/scan-config.yaml**` (Your Automation Framework logic).
* *Tip:* Double-check that the `urls` in your config match your actual target.
* *Tip:* Ensure `browserId: "firefox-headless"` is used as planned for the AJAX spider.



### 3. Network & Security Tweak

* **SSL Certificates:** Since you mentioned **SonicWall DPI-SSL**, ZAP might throw "SSL Handshake" errors.
* If the scan fails immediately, you will need to import the SonicWall CA certificate into ZAP's JRE trust store or use the `disableAll` verification (not recommended for production).


* **API Key:** Since you are running in `-cmd` (inline) mode rather than as a long-running daemon, a fixed API key is less critical, but good for future-proofing.

### 4. Running the Scan

To start the process, simply run:

```bash
docker-compose up

```

* **Monitor Logs:** Use `docker logs -f zap-scanner` to watch the progress.
* **Resource Check:** Run `docker stats` in another terminal to see if ZAP is actually hitting that 12GB RAM limit during the AJAX spidering phase.

### 5. Post-Scan Maintenance

* **Cleanup Cron Job:** Set up the auto-purge for old sessions.
```bash
crontab -e
# Add this line to delete .session files older than 14 days every Sunday at midnight
0 0 * * 0 find ~/zap-scanner/wrk -name "*.session" -type f -mtime +14 -delete

```
---

### Troubleshooting Common Issues

| Issue | Fix |
| --- | --- |
| **Permission Denied** | Usually means the Docker container can't write the report to the `./wrk` folder. Check `chmod`. |
| **0 Links Found** | The Spider likely hit a login page. You may need to add an "Authentication" section to your YAML later. |
| **Out of Memory** | If the scan crashes, reduce `numberOfBrowsers` in the `ajaxSpider` section from 2 to 1. |
