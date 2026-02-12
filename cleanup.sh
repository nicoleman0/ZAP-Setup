#!/bin/bash
# Find and delete ZAP session and log files older than 14 days
# This is going to be in opt/zap/cleanup.sh

find /path/to/your/wrk/reports -name "*.session" -mtime +14 -exec rm {} \;
find /path/to/your/wrk/reports -name "*.log" -mtime +14 -exec rm {} \;


# Then set up the cron -> `crontab -e`
# Runs every Sunday at Midnight
# 0 0 * * 0 /bin/bash /opt/zap/cleanup.sh
