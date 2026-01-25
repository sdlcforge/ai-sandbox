#!/bin/bash
set -euo pipefail  # Exit on error, undefined vars, and pipeline failures
IFS=$'\n\t'        # Stricter word splitting (excludes space to handle filenames safely)

# 1. Extract Docker DNS info BEFORE any flushing
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)  # Capture Docker's internal DNS NAT rules for later restoration

# 2. Flush existing rules and delete existing ipsets
iptables -F                            # Flush all rules in the filter table
iptables -X                            # Delete all user-defined chains in filter table
iptables -t nat -F                     # Flush all rules in the NAT table
iptables -t nat -X                     # Delete all user-defined chains in NAT table
iptables -t mangle -F                  # Flush all rules in the mangle table
iptables -t mangle -X                  # Delete all user-defined chains in mangle table
ipset destroy allowed-domains 2>/dev/null || true  # Destroy existing allowed-domains ipset if it exists

# 3. Allow connections to github.com and all subdomains
iptables -A OUTPUT -p tcp -d github.com --dport 22 -j ACCEPT            # Allow SSH to github.com (git push/pull)
iptables -A OUTPUT -p tcp -d github.com --dport 443 -j ACCEPT           # Allow HTTPS to github.com
iptables -A OUTPUT -p tcp -d github.com --dport 80 -j ACCEPT            # Allow HTTP to github.com
iptables -A OUTPUT -p tcp -d .github.com --dport 22 -j ACCEPT           # Allow SSH to *.github.com subdomains
iptables -A OUTPUT -p tcp -d .github.com --dport 443 -j ACCEPT          # Allow HTTPS to *.github.com subdomains
iptables -A OUTPUT -p tcp -d .github.com --dport 80 -j ACCEPT           # Allow HTTP to *.github.com subdomains
iptables -A OUTPUT -p tcp -d githubusercontent.com --dport 443 -j ACCEPT      # Allow HTTPS to githubusercontent.com (raw content)
iptables -A OUTPUT -p tcp -d .githubusercontent.com --dport 443 -j ACCEPT     # Allow HTTPS to *.githubusercontent.com subdomains
iptables -A OUTPUT -p tcp -d githubassets.com --dport 443 -j ACCEPT           # Allow HTTPS to githubassets.com (static assets)
iptables -A OUTPUT -p tcp -d .githubassets.com --dport 443 -j ACCEPT          # Allow HTTPS to *.githubassets.com subdomains
iptables -A OUTPUT -p tcp -d anthropic.com --dport 443 -j ACCEPT           # Allow HTTPS to anthropic.com
iptables -A OUTPUT -p tcp -d .anthropic.com --dport 443 -j ACCEPT          # Allow HTTPS to *.anthropic.com subdomains

# 4. Restore Docker internal DNS NAT rules
if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "$DOCKER_DNS_RULES" | while read -r rule; do
        # Restore each captured NAT rule for Docker's embedded DNS
        iptables-restore --noflush <<< "$rule" 2>/dev/null || true
    done
fi
