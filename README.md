# Forge DB Backup

A simple and secure bash script to backup MySQL databases to S3-compatible storage services (Cloudflare R2, AWS S3, MinIO, etc.). Designed for [Laravel Forge](https://forge.laravel.com) but works on any server and with any MySQL/MariaDB database.

The script is setup and managed as a Laravel Forge website without the need to SSH into the server leveraging Forge's environment management, scheduler and heartbeat monitoring.

## Features

- 🗄️ Backup multiple MySQL databases
- ☁️ Upload to any S3-compatible storage
- 🧹 Automatic cleanup of old backups (local and remote)
- 🚫 Exclude specific tables from backup (e.g., logs, search indexes)
- 💓 Optional heartbeat monitoring (e.g., Laravel Pulse, Uptime Kuma)
- 🔒 Secure credential handling

## How It Works

1. **Backup**: Creates compressed SQL dumps of each database in a consistent state
2. **Upload**: Syncs backups to S3-compatible storage
3. **Cleanup**: Removes old backups (keeps only the latest N files per database)
4. **Heartbeat**: Pings monitoring URL on success (optional)

## Requirements

- Bash
- MySQL/MariaDB with `mysqldump`
- AWS CLI (for S3 upload)
- `curl` (for heartbeat monitoring, optional)

## Installation on Laravel Forge

### 1. Clone the repository

First, clone this repository so you can deploy it to your Forge site.

### 2. Create a new site

Create a new PHP site in Laravel Forge:
- Don't connect any database;
- Choose any Forge domain (e.g. `mybackup.on-forge.com`);
- Don't install Composer dependencies;
- In **Advanced settings** make sure the **Web directory** is set to `/public`;
- Disable **Zero downtime deployments**.

Now, deploy the site.

### 3. Configure environment

Go to **Settings** -> **Environment** tab of your Forge site. Here you can set your MySQL database connection, S3 storage configuration and set which databases to backup, which tables to ignore and set the number of backups per database to keep.

If you don't have a heartbeat URL yet, you can leave that field empty for now. You will be given one when you set up a scheduled task later.

### 4. Set permissions

Go to the **Settings** -> **Deployments** tab of your Forge site and add the following command into the end of the **Deploy script**:

```bash
chmod +x $FORGE_SITE_PATH/backup.sh
```

This makes the backup script executable.

### 5. Schedule backups

Go to **Processes** -> **Scheduler** tab of your Forge site and create a new scheduled task. Give it any name you like, e.g. `Database Backup`.

- Command: `/home/forge/mybackup.on-forge.com/backup.sh` - replace `mybackup.on-forge.com` with your actual site domain
- Frequency: Choose how often you want to run the backup (e.g., nightly)
- Enable **Monitor with heartbeats**

After saving, click three dots next to the scheduled task and select **Copy Heartbeat URL**. Copy the URL and paste it into the `HEARTBEAT_URL` environment variable in the **Settings** -> **Environment** tab.

## Ignoring tables

Many CMS and frameworks create large tables that store temporary or regeneratable data. Sometimes such tables may double or triple the size of your database backups without adding any real value. Excluding these tables reduces backup size and time.

**Common Laravel tables to exclude:**

```env
# Sessions and cache
IGNORE_TABLES="myapp.sessions,myapp.cache,myapp.cache_locks"

# Laravel Horizon
IGNORE_TABLES="myapp.jobs,myapp.failed_jobs,myapp.job_batches"

# Laravel Telescope
IGNORE_TABLES="myapp.telescope_entries,myapp.telescope_entries_tags,myapp.telescope_monitoring"

# Laravel Pulse
IGNORE_TABLES="myapp.pulse_entries,myapp.pulse_aggregates,myapp.pulse_values"

# Laravel Nova (action events can get large)
IGNORE_TABLES="myapp.action_events"

# Full-text search indexes (can be rebuilt)
IGNORE_TABLES="myapp.scout_index"
```
