#!/bin/sh
set -eu

script=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)/fix-kmod-iptables-deps.sh
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/package/kernel/linux/modules" "$root/package/example" "$root/feeds/example"

cat > "$root/package/kernel/linux/modules/netfilter.mk" <<'EOF'
define KernelPackage/nf-ipt
  DEPENDS:=+!LINUX_6_12:kmod-iptables
endef
define KernelPackage/other
  DEPENDS:=+kmod-iptables
endef
EOF
printf 'DEPENDS:=+kmod-iptables\n' > "$root/package/example/Makefile"
printf 'DEPENDS:=+kmod-iptables\n' > "$root/feeds/example/Makefile"

sh "$script" "$root" >/dev/null
grep -Fqx '  DEPENDS:=+!LINUX_6_12:kmod-iptables' "$root/package/kernel/linux/modules/netfilter.mk"
grep -Fqx '  DEPENDS:=+kmod-nf-ipt' "$root/package/kernel/linux/modules/netfilter.mk"
grep -Fqx 'DEPENDS:=+kmod-nf-ipt' "$root/package/example/Makefile"
grep -Fqx 'DEPENDS:=+kmod-nf-ipt' "$root/feeds/example/Makefile"

echo 'kmod-iptables dependency rewrite preserves nf-ipt and updates consumers.'
