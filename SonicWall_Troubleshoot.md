To ensure ZAP can communicate through SonicWall's Deep Packet Inspection (DPI), I will need to inject the SonicWall CA certificate into the Java TrustStore inside the running container.

Since I am using Docker, the most "permanent" and cleanest way to do this is to mount the certificate as a volume and use a wrapper command to import it before the scan starts.

### 1. Place the Certificate

Save your SonicWall CA certificate (e.g., `sonicwall-ca.crt`) in your `~/zap-scanner/wrk/` directory.

### 2. Update `docker-compose.yaml`

Modify your compose file to perform the import at runtime. We use `keytool`, which is the standard utility for managing Java keystores.

```yaml
services:
  zap:
    image: zaproxy/zap-stable
    container_name: zap-scanner
    user: root # Temporarily root to allow keytool to modify the cacerts file
    deploy:
      resources:
        limits:
          cpus: '7.5'
          memory: 12G
    volumes:
      - ./wrk:/zap/wrk:rw
    entrypoint: /bin/bash -c
    command: >
      "keytool -import -trustcacerts -alias sonicwall -file /zap/wrk/sonicwall-ca.crt 
      -keystore /usr/lib/jvm/java-11-openjdk-amd64/lib/security/cacerts 
      -storepass changeit -noprompt &&
      su zap -c 'zap.sh -cmd -autorun /zap/wrk/scan-config.yaml'"

```

---

### Key Technical Details

* **Default Password:** The default password for the Java TrustStore (`cacerts`) is almost always `changeit`.
* **Pathing:** The path `/usr/lib/jvm/java-11-openjdk-amd64/lib/security/cacerts` is standard for the `zap-stable` image, but if the image updates its Java version, you may need to verify the path.
* **Permissions:** We start as `root` to modify the system-level Java store, then use `su zap` to execute the actual scan as the standard `zap` user for security best practices.

### Alternative: The "ZAP Way"

If you prefer not to touch the Java TrustStore, you can also tell ZAP to ignore SSL errors via the Automation Framework `env` parameters, though this is less secure:

```yaml
# Inside your scan-config.yaml
parameters:
  failOnError: true
  failOnWarning: false
  continueOnFailure: false
  # Add this to the options:
  options:
    connection.skipCertificateCheck: true

```

### Verification

If the import works, you will see `Certificate was added to keystore` in your Docker logs immediately before the ZAP splash screen text appears.
