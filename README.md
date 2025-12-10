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
- Clean up log files

## Security Considerations

- Santa logs contain detailed execution information including arguments, which may contain sensitive data
- In Lockdown mode, ensure you have a recovery plan if critical binaries are accidentally blocked
- Regularly review and update your allowlist/blocklist rules
- Monitor Santa logs in Wazuh for suspicious execution patterns

## Contributing

Contributions are welcome! Please open an issue or submit a pull request for any improvements or bug fixes.

## Resources

- [Northpole Santa GitHub Repository](https://github.com/northpolesec/santa)
- [Santa Documentation](https://northpole.dev/intro)
- [Wazuh Documentation](https://documentation.wazuh.com/)
- [macOS System Extensions Guide](https://developer.apple.com/documentation/systemextensions)ers/*/Desktop/*</

## Troubleshooting

1. **Permission Errors**: All commands must be run with sudo/administrator privileges.

2. **Santa Not Logging**: Verify the log file exists and has proper permissions:
   ```bash
   sudo ls -la /var/log/santa.log
   ```

4. **System Extension Not Loading**: After macOS updates, you may need to re-approve the system extension or reinstall Santa.

## Contributing
We welcome contributions from the community! If you have any improvements or bug fixes, please open an issue or submit a pull request.
