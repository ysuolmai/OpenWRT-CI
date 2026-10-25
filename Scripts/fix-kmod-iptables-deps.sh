#!/bin/sh
set -eu

root=${1:-.}
cd "$root"

affected=$(grep -rl '+kmod-iptables' package/ feeds/ 2>/dev/null || true)
if [ -z "$affected" ]; then
	echo '[pkg-fix] no kmod-iptables dependencies found'
	exit 0
fi

printf '%s\n' "$affected" | while IFS= read -r makefile; do
	[ -n "$makefile" ] || continue
	# Rewrite consumers, but leave the kmod-nf-ipt package's own dependency intact.
	sed -i -E '/^define KernelPackage\/nf-ipt$/,/^endef$/! s/\+kmod-iptables([^a-zA-Z0-9_-]|$)/+kmod-nf-ipt\1/g' "$makefile"
done

echo "[pkg-fix] updated $(printf '%s\n' "$affected" | wc -l | tr -d ' ') makefile(s); kept nf-ipt self-dependency unchanged"
