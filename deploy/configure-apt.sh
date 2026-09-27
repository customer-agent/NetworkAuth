#!/bin/sh
# Bookworm base images use either deb822 sources or the legacy sources.list.
# Only replace archive URLs; retain suites, components and signing keys.
set -eu

APT_MIRROR=${APT_MIRROR:-http://deb.debian.org/debian}
APT_SECURITY_MIRROR=${APT_SECURITY_MIRROR:-http://deb.debian.org/debian-security}
for mirror in "$APT_MIRROR" "$APT_SECURITY_MIRROR"; do
    case "$mirror" in
        http://?*|https://?*) ;;
        *) echo 'APT mirror must be an http:// or https:// URL' >&2; exit 1 ;;
    esac
    # These characters would change the sed replacement rather than its URL.
    case "$mirror" in
        *[!a-zA-Z0-9:/._~-]*) echo 'Unsupported character in APT mirror URL' >&2; exit 1 ;;
    esac
done

for source_file in /etc/apt/sources.list /etc/apt/sources.list.d/debian.sources; do
    [ -f "$source_file" ] || continue
    sed -i \
        -e "s|http://deb.debian.org/debian-security|${APT_SECURITY_MIRROR%/}|g" \
        -e "s|https://deb.debian.org/debian-security|${APT_SECURITY_MIRROR%/}|g" \
        -e "s|http://security.debian.org/debian-security|${APT_SECURITY_MIRROR%/}|g" \
        -e "s|https://security.debian.org/debian-security|${APT_SECURITY_MIRROR%/}|g" \
        -e "s|http://deb.debian.org/debian|${APT_MIRROR%/}|g" \
        -e "s|https://deb.debian.org/debian|${APT_MIRROR%/}|g" \
        "$source_file"
done
