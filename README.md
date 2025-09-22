# STIPSync - Azure Service Tag IP Sync

```text
╔═══════════════════════════════════════════════════════════════════════╗
║                                                                       ║
║     ███████╗████████╗██╗██████╗ ███████╗██╗   ██╗███╗   ██╗ ██████╗   ║
║     ██╔════╝╚══██╔══╝██║██╔══██╗██╔════╝╚██╗ ██╔╝████╗  ██║██╔════╝   ║
║     ███████╗   ██║   ██║██████╔╝███████╗ ╚████╔╝ ██╔██╗ ██║██║        ║
║     ╚════██║   ██║   ██║██╔═══╝ ╚════██║  ╚██╔╝  ██║╚██╗██║██║        ║
║     ███████║   ██║   ██║██║     ███████║   ██║   ██║ ╚████║╚██████╗   ║
║     ╚══════╝   ╚═╝   ╚═╝╚═╝     ╚══════╝   ╚═╝   ╚═╝  ╚═══╝ ╚═════╝   ║
║                                                                       ║
║                STIPSync – Azure Service Tag IP Sync                   ║
║                             v1.0.0                                    ║
║                                                                       ║
║   Sync Azure Service Tag IPs into resource firewall allowlists with   ║
║   a single bulk update.                                               ║
║                                                                       ║
╚═══════════════════════════════════════════════════════════════════════╝
```

STIPSync syncs Azure Service Tag IP ranges into resource firewall allowlists using a single bulk update, minimizing activity log noise.

## Features
- Parses the latest Azure Service Tags JSON automatically
- Supports region keys like `AzureCloud.eastasia`
- Computes removals and additions and applies them in one update
- Reports actually added/removed IPs

## Requirements
- Azure CLI (`az`)
- `jq`
- `curl`

## Usage
```bash
./stipsync.sh -s <storageAccountName> -g <resourceGroupName> -r "AzureCloud.eastasia"
```

## Options
- `-h, --help`   Show help
- `-v, --version` Show version

## How it works
1. Fetches the current ServiceTags JSON filename from Microsoft download page
2. Downloads the JSON blob
3. Extracts IPv4 prefixes for the specified service tag region
4. Diffs against current IP rules
5. Updates `properties.networkRuleSet.ipRules` via `az resource update` in one operation

## Notes
- Current implementation targets Storage Accounts. Extensible to Key Vault and other resources with similar IP rule models.
- One bulk update → one activity log entry.
