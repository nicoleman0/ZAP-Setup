## OWASP ZAP VM: Specifications

| Component | Specification | Rationale |
| :--- | :--- | :--- |
| **Operating System** | Ubuntu 24.04 LTS (Headless) | Minimizes resource overhead, ensuring maximum hardware resources are dedicated to the scan. 24.04 also provides long-term stable environment. 1.5-2x faster than Windows Server. |
| **CPU** | 8 Cores (recommended) / 4 cores (minimum) | 8 cores allow ZAP to handle high thread concurrency without bottlenecks. 4 cores is minimum to manage the OS, Java Virtual Machine overhead, and baseline spidering. |
| **RAM** | 12 GB RAM (recommended) / 8 GB RAM (minimum) | 12GB would make the scans faster, but 8GB of RAM is absolutely necessary (very memory intensive). |
| **Storage** | 100 GB (recommended) / 60 GB (minimum) | Local storage of ZAP binaries and session data. Large scans can fill up storage quickly. (Can also configure ZAP to give a smaller PDF report and delete the heavy session file) |
