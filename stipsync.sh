#!/usr/bin/env bash

set -euo pipefail

VERSION="1.0.0"

cat_banner() {
  cat <<'BANNER'
╔═══════════════════════════════════════════════════════════════════════╗
║                                                                       ║
║     ███████╗████████╗██╗██████╗ ███████╗██╗   ██╗███╗   ██╗ ██████╗   ║
║     ██╔════╝╚══██╔══╝██║██╔══██╗██╔════╝╚██╗ ██╔╝████╗  ██║██╔════╝   ║
║     ███████╗   ██║   ██║██████╔╝███████╗ ╚████╔╝ ██╔██╗ ██║██║        ║
║     ╚════██║   ██║   ██║██╔═══╝ ╚════██║  ╚██╔╝  ██║╚██╗██║██║        ║
║     ███████║   ██║   ██║██║     ███████║   ██║   ██║ ╚████║╚██████╗   ║
║     ╚══════╝   ╚═╝   ╚═╝╚═╝     ╚══════╝   ╚═╝   ╚═╝  ╚═══╝ ╚═════╝   ║
║                                                                       ║
║                   STIPSync – Az Service Tag IP Sync                   ║
║                             v1.0.0                                    ║
║                                                                       ║
║   Sync Azure Service Tag IPs into resource firewall allowlists with   ║
║   a single bulk update.                                               ║
║                                                                       ║
╚═══════════════════════════════════════════════════════════════════════╝
BANNER
}

print_usage() {
  cat_banner
  echo ""
  echo "Usage: stipsync.sh -s <storageAccountName> -g <resourceGroupName> -r <regionName>" >&2
  echo ""
  echo "Arguments:" >&2
  echo "  -s   Storage Account name" >&2
  echo "  -g   Resource Group name" >&2
  echo "  -r   Region name (e.g., AzureCloud.eastasia)" >&2
  echo ""
  echo "Options:" >&2
  echo "  -h, --help       Show help" >&2
  echo "  -v, --version    Show version" >&2
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  print_usage
  exit 0
fi

if [[ "${1:-}" == "--version" || "${1:-}" == "-v" ]]; then
  echo "STIPSync v${VERSION}"
  exit 0
fi

storageAccountName=""
resourceGroupName=""
regionName=""

while getopts ":s:g:r:hv" opt; do
  case "$opt" in
    s) storageAccountName="$OPTARG" ;;
    g) resourceGroupName="$OPTARG" ;;
    r) regionName="$OPTARG" ;;
    h) print_usage; exit 0 ;;
    v) echo "STIPSync v${VERSION}"; exit 0 ;;
    *) print_usage; exit 2 ;;
  esac
done

if [[ -z "$storageAccountName" || -z "$resourceGroupName" || -z "$regionName" ]]; then
  print_usage; exit 2
fi

command -v az >/dev/null 2>&1 || { echo "az CLI is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }

cat_banner
echo "Downloading Azure Service Tags JSON reference..."
download_page_url="https://www.microsoft.com/en-us/download/details.aspx?id=56519"
page_content="$(curl -fsSL "$download_page_url")"

# Extract the current ServiceTags filename e.g. ServiceTags_Public_YYYYMMDD.json
file_name="$(printf "%s" "$page_content" | grep -o 'ServiceTags_Public_[0-9]\{8\}\.json' | head -n1)"
if [[ -z "$file_name" ]]; then
  echo "Failed to parse ServiceTags filename from Microsoft download page" >&2
  exit 1
fi

blob_base="https://download.microsoft.com/download/7/1/D/71D86715-5596-4529-9B13-DA13A5DE5B63"
json_url="$blob_base/$file_name"
echo "Using file: $file_name"
echo "Downloading JSON: $json_url"

json_tmp="$(mktemp)"
trap 'rm -f "$json_tmp" "$ips_tmp" "$new_rules_tmp" "$merged_rules_tmp"' EXIT

curl -fsSL "$json_url" -o "$json_tmp"

echo "Processing region: $regionName"

# Collect address prefixes for exact region name (e.g., AzureCloud.eastasia)
mapfile -t region_addresses < <(
  jq -r --arg rn "$regionName" '
    .values[] | select(.name == $rn) | .properties.addressPrefixes[] // empty
  ' "$json_tmp"
)

if [[ ${#region_addresses[@]} -eq 0 ]]; then
  echo "No addresses found for region '$regionName'" >&2
  exit 1
fi

# Filter IPv4 only and strip /31 or /32 suffixes
ips_tmp="$(mktemp)"
printf "%s\n" "${region_addresses[@]}" \
  | grep -v ':' \
  | sed -E 's#/(31|32)$##' \
  | sort -u > "$ips_tmp"

ip_count=$(wc -l < "$ips_tmp" | tr -d ' ')
echo "IPv4 ranges prepared: $ip_count"

echo "Fetching current storage account IP rules..."
current_rules_json="$(az storage account show -g "$resourceGroupName" -n "$storageAccountName" --query "networkRuleSet" -o json)"
mapfile -t current_ip_rules < <(printf "%s" "$current_rules_json" | jq -r '.ipRules[]?.ipAddressOrRange')

current_count=${#current_ip_rules[@]}
max_limit=400
remaining=$(( max_limit - current_count ))
if (( remaining < 0 )); then remaining=0; fi
echo "Existing rules: $current_count; Remaining capacity: $remaining"

# Compute toRemove (present in current, not in new)
mapfile -t new_list < "$ips_tmp"

to_remove=()
declare -A new_set=()
for ip in "${new_list[@]}"; do new_set["$ip"]=1; done
for ip in "${current_ip_rules[@]:-}"; do
  [[ -n "${new_set[$ip]:-}" ]] || to_remove+=("$ip")
done

# Compute toAdd (present in new, not in current), respecting capacity
declare -A curr_set=()
for ip in "${current_ip_rules[@]:-}"; do curr_set["$ip"]=1; done

to_add_all=()
for ip in "${new_list[@]}"; do
  [[ -n "${curr_set[$ip]:-}" ]] || to_add_all+=("$ip")
done

to_add=()
for ip in "${to_add_all[@]}"; do
  if (( remaining <= 0 )); then break; fi
  to_add+=("$ip")
  remaining=$(( remaining - 1 ))
done

echo "Planned removals: ${#to_remove[@]}"
echo "Planned additions: ${#to_add[@]}"

# Build merged rule list: (current - to_remove) + to_add
merged_rules_tmp="$(mktemp)"

# Start from current minus removals
{
  for ip in "${current_ip_rules[@]:-}"; do
    skip=0
    for r in "${to_remove[@]}"; do
      if [[ "$ip" == "$r" ]]; then skip=1; break; fi
    done
    (( skip == 0 )) && printf "%s\n" "$ip"
  done
  # Then append additions
  for ip in "${to_add[@]}"; do printf "%s\n" "$ip"; done
} | sort -u > "$merged_rules_tmp"

echo "Applying bulk update (single activity log entry)..."

# Convert to ARM ipRules JSON: [{"action":"Allow","value":"IP"}, ...]
new_rules_tmp="$(mktemp)"
jq -R -s -c '[.[] | select(length>0)] | split("\n") | map(select(length>0)) | map({action:"Allow", value:.})' < "$merged_rules_tmp" > "$new_rules_tmp"

# Use az resource update to set properties.networkRuleSet.ipRules in one call
storage_id="$(az storage account show -g "$resourceGroupName" -n "$storageAccountName" --query id -o tsv)"

json_compact="$(cat "$new_rules_tmp")"

az resource update --ids "$storage_id" \
  --set "properties.networkRuleSet.ipRules=$json_compact" >/dev/null

echo "Bulk update completed successfully."

# Report effective changes
after_ips=( $(az storage account show -g "$resourceGroupName" -n "$storageAccountName" --query "networkRuleSet.ipRules[].ipAddressOrRange" -o tsv || true) )

actually_added=()
actually_removed=()

declare -A before_set=()
for ip in "${current_ip_rules[@]:-}"; do before_set["$ip"]=1; done
declare -A after_set=()
for ip in "${after_ips[@]:-}"; do after_set["$ip"]=1; done

for ip in "${after_ips[@]:-}"; do [[ -z "${before_set[$ip]:-}" ]] && actually_added+=("$ip"); done
for ip in "${current_ip_rules[@]:-}"; do [[ -z "${after_set[$ip]:-}" ]] && actually_removed+=("$ip"); done

if (( ${#actually_added[@]} > 0 )); then
  echo "Newly added IPs: ${actually_added[*]}"
fi
if (( ${#actually_removed[@]} > 0 )); then
  echo "Removed IPs: ${actually_removed[*]}"
fi

echo "Done."


