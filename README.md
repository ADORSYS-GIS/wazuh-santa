# Wazuh Santa Integration

This repository contains scripts to install and configure Santa for integration with Wazuh endpoint security platform. Santa is a binary authorization system for macOS that monitors process executions and can blacklist/whitelist binaries and certificates.

## Prerequisites

1. macOS 10.15 (Catalina) or higher
2. Administrator/sudo privileges
3. Internet connectivity to download Santa from GitHub
4. Wazuh agent installed on the macOS system

## Installation

1. Open Terminal.
2. Download and execute the installation script:
   ```bash
   curl -sL 'https://raw.githubusercontent.com/ADORSYS-GIS/wazuh-santa/main/scripts/install.sh' \
   -o /tmp/install.sh && sudo bash /tmp/install.sh
   ```

This will:
- Automatically download the latest Santa release from northpolesec's GitHub repository
- Install Santa system extension
- Configure Santa to log data exfiltration with lotl tools
- Set up Syslog logging format for better Wazuh integration
- Configure Wazuh to collect Santa logs
- Restart the Wazuh agent
- Clean up temporary files

## Uninstallation

To uninstall Santa and remove the Wazuh configuration:

1. Open Terminal.
2. Download and execute the uninstallation script:
   ```bash
   curl -sL 'https://raw.githubusercontent.com/ADORSYS-GIS/wazuh-santa/main/scripts/uninstall.sh' \
   -o /tmp/uninstall.sh && sudo bash /tmp/uninstall.sh
   ```

This will:
- Stop and unload the Santa system extension
- Remove Santa binaries and configuration files
- Remove Santa configuration from Wazuh
- Restart the Wazuh agent
- Clean up log files

## Configuration

* Runs in **Monitor Mode** (no blocking, logs only)
* Logs all executions: arguments, hashes, parent/child, signing info
* Uses **syslog** format with automatic log rotation
* Tracks LOTL binaries: `curl`, `scp`, `sftp`, `rsync`, `nc`, `python3`
* Monitors sensitive paths: `~/Documents`, `~/Desktop`, `~/.ssh`, `~/.aws`
* Uses Santa `ProcessesWithDeniedPaths` rule in **AuditOnly** mode
* Enables full detail logging for Wazuh visibility


## Manual Wazuh Configuration

If the automatic configuration fails, you can manually add the following to:
- Wazuh configuration file (`/Library/Ossec/etc/ossec.conf`):

```xml
<localfile>
  <log_format>syslog</log_format>
  <location>/var/log/santa.log</location>
</localfile>
```
- Santa configuration file (`/var/db/santa/config.plist`):
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Version</key>
    <string>v1.0</string>
    <key>WatchItems</key>
    <dict>
        <!-- Monitor LOTL binaries accessing sensitive paths -->
        <key>LOTLDataExfiltration</key>
        <dict>
            <key>Paths</key>
            <array>
                <!-- Protect sensitive directories -->
                <dict>
                    <key>Path</key>
                    <string>/Users/*/Documents/*</string>
                    <key>IsPrefix</key>
                    <true/>
                </dict>
                <dict>
                    <key>Path</key>
                    <string>/Us
## Advanced Configuration

### Custom Rule Sync

Santa supports syncing rules from a central server. To configure:

1. Edit `/var/db/santa/config.plist`
2. Add sync server URL:
   ```xml
   <key>SyncBaseURL</key>
   <string>https://your-sync-server.com/api/santa/</string>
   ```

### Custom Blocking Rules

To block specific binaries:

```bash
# Block by SHA-256 hash
sudo santactl rule --blockhash <sha256-hash>

# Block by certificate
sudo santactl rule --blockcert <certificate-sha256>
```

### Performance Tuning

For high-volume environments, adjust log rotation settings in `/var/db/santa/config.plist`:

```xml
<key>FileChangesMaxFileSizeKB</key>
<integer>10240</integer>
<key>FileChangesMaxFilesCount</key>
<integer>100</integer>
```

## Security Considerations

- Santa logs contain detailed execution information including arguments, which may contain sensitive data
- In Lockdown mode, ensure you have a recovery plan if critical binaries are accidentally blocked
- Regularly review and update your allowlist/blocklist rules
- Monitor Santa logs in Wazuh for suspicious execution patterns

## Contributing

Contributions are welcome! Please open an issue or submit a pull request for any improvements or bug fixes.

## Resources

- [Google Santa GitHub Repository](https://github.com/google/santa)
- [Santa Documentation](https://santa.dev/)
- [Wazuh Documentation](https://documentation.wazuh.com/)
- [macOS System Extensions Guide](https://developer.apple.com/documentation/systemextensions)ers/*/Desktop/*</string>
                    <key>IsPrefix</key>
                    <true/>
                </dict>
                <dict>
                    <key>Path</key>
                    <string>/Users/*/.ssh/*</string>
                    <key>IsPrefix</key>
                    <true/>
                </dict>
                <dict>
                    <key>Path</key>
                    <string>/Users/*/.aws/*</string>
                    <key>IsPrefix</key>
                    <true/>
                </dict>
            </array>
            <key>Options</key>
            <dict>
                <key>RuleType</key>
                <string>ProcessesWithDeniedPaths</string>
                <key>AuditOnly</key>
                <true/>  <!-- Start with logging only -->
                <key>AllowReadAccess</key>
                <false/>
            </dict>
            <key>Processes</key>
            <array>
                <!-- Common LOTL binaries for exfiltration -->
                <dict>
                    <key>BinaryPath</key>
                    <string>/usr/bin/curl</string>
                </dict>
                <dict>
                    <key>BinaryPath</key>
                    <string>/usr/bin/scp</string>
                </dict>
                <dict>
                    <key>BinaryPath</key>
                    <string>/usr/bin/sftp</string>
                </dict>
                <dict>
                    <key>BinaryPath</key>
                    <string>/usr/bin/rsync</string>
                </dict>
                <dict>
                    <key>BinaryPath</key>
                    <string>/usr/bin/nc</string>
                </dict>
                <dict>
                    <key>BinaryPath</key>
                    <string>/usr/bin/python3</string>
                </dict>
            </array>
        </dict>
    </dict>
</dict>
</plist>
```

After adding this configuration, restart the Wazuh agent:

```bash
sudo /Library/Ossec/bin/wazuh-control restart
```

## Verification

After installation, you can verify that Santa is running:

```bash
# Check Santa status
santactl status

# View recent Santa logs
tail -f /var/log/santa.log

santactl doctor
```

You can also verify Wazuh is collecting Santa events:

```bash
# Check Wazuh agent log for Santa events
sudo tail -f /Library/Ossec/logs/ossec.log | grep santa
```

## Troubleshooting

1. **Permission Errors**: All commands must be run with sudo/administrator privileges.

2. **Santa Not Logging**: Verify the log file exists and has proper permissions:
   ```bash
   sudo ls -la /var/log/santa.log
   ```

3. **Wazuh Agent Issues**: If the Wazuh agent fails to restart:
   ```bash
   sudo /Library/Ossec/bin/wazuh-control status
   sudo /Library/Ossec/bin/wazuh-control start
   ```

4. **System Extension Not Loading**: After macOS updates, you may need to re-approve the system extension or reinstall Santa.

## Contributing
We welcome contributions from the community! If you have any improvements or bug fixes, please open an issue or submit a pull request.
