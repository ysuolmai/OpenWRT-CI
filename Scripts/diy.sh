#!/bin/bash

# =======================================================
# [section: config-helpers] 统一维护 OpenWrt .config
# =======================================================
# value 支持 y/m/n、带引号的值、unset（显式 not set）和 remove（删除配置行）。
set_config() {
    local config_name="$1"
    local config_value="$2"
    local config_key="CONFIG_${config_name}"

    if ! awk -v key="$config_key" '
        index($0, key "=") == 1 || $0 == "# " key " is not set" { next }
        { print }
    ' .config > .config.new; then
        echo "[config] 错误：无法更新 .config 中的 $config_key"
        return 1
    fi
    if ! mv .config.new .config; then
        echo "[config] 错误：无法替换 .config"
        return 1
    fi

    case "$config_value" in
        remove)
            ;;
        unset)
            if ! printf '# %s is not set\n' "$config_key" >> .config; then
                echo "[config] 错误：无法写入 $config_key"
                return 1
            fi
            ;;
        *)
            if ! printf '%s=%s\n' "$config_key" "$config_value" >> .config; then
                echo "[config] 错误：无法写入 $config_key"
                return 1
            fi
            ;;
    esac
}

# =======================================================
# [upstream-fix] 删除上游 immortalwrt 格式损坏的 globitel-bt-r320 patch
# 该 patch (immortalwrt commit a3105d3f, 2026-05-07) 在 line 162/218 处
# 相邻多个 `--- /dev/null` 块之间缺 `diff --git` file-boundary header，
# 用 patch(1) plaintext 模式 apply 时报 "malformed patch at line 162"，
# 导致所有 MT7981 u-boot variant (abt_asr3000 / sx_7981r128 等) 编译失败。
# 我们不用 globitel-bt-r320 设备，直接删除该 patch。
# 上游修复后此 hook 会自然 no-op（文件不存在则跳过）。
# =======================================================
BROKEN_UBOOT_PATCH="package/boot/uboot-mediatek/patches/472-add-globitel-bt-r320.patch"
if [ -f "$BROKEN_UBOOT_PATCH" ]; then
    echo "[upstream-fix] 删除格式损坏的 $BROKEN_UBOOT_PATCH"
    rm -f "$BROKEN_UBOOT_PATCH"
fi

# =======================================================
# [device-add] 注入 SX 7981R128 设备支持
# 该设备不在 VIKINGYFY/immortalwrt 源码中，需要本 CI 注入
# - DTS：Scripts/dts/mt7981b-sx-7981r128.dts
# - 设备条目：追加到 target/linux/mediatek/image/filogic.mk
# - board.d：注入网络/MAC/LED/升级校验，端口布局保留本仓库设定
# - uboot-envtools / mtk-smp：跟进上游 zhao,7981r128 支持，文件存在时才注入
# - 仅 MTK 平台需要，其他平台（IPQ60XX/IPQ807X/Rockchip/x86）无影响
# - FIP / BL2 / U-Boot 的构建在独立项目 https://github.com/ysuolmai/UBOOT-CI
#   这里只产 sysupgrade.bin / factory.bin，不掺和 U-Boot
# =======================================================
SX7981_DTS_SRC="${GITHUB_WORKSPACE}/Scripts/dts/mt7981b-sx-7981r128.dts"
SX7981_FILOGIC_MK="target/linux/mediatek/image/filogic.mk"
SX7981_UBOOT_ENVTOOLS="package/boot/uboot-tools/uboot-envtools/files/mediatek_filogic"
SX7981_SMP_SH="package/mtk/applications/mtk-smp/files/smp.sh"

if [[ "$WRT_CONFIG" == "MEDIATEK-"* || "$WRT_CONFIG" == "MTK-"* ]] && \
   [ -f "$SX7981_DTS_SRC" ] && [ -d "target/linux/mediatek/dts" ]; then
    echo "================================================================"
    echo "[device-add] 注入 SX 7981R128 设备支持..."

    # 1. 复制 DTS
    cp -f "$SX7981_DTS_SRC" target/linux/mediatek/dts/
    echo "[device-add]   DTS 已复制到 target/linux/mediatek/dts/"

    # 2. 追加设备到 filogic.mk（幂等：已存在则跳过）
    if [ -f "$SX7981_FILOGIC_MK" ] && ! grep -q '^define Device/sx_7981r128' "$SX7981_FILOGIC_MK"; then
        cat >> "$SX7981_FILOGIC_MK" << 'FILOGIC_EOF'

define Device/sx_7981r128
  DEVICE_VENDOR := SX
  DEVICE_MODEL := 7981R128
  DEVICE_DTS := mt7981b-sx-7981r128
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware kmod-usb3 \
                     kmod-sfp kmod-i2c-gpio automount f2fsck mkf2fs uboot-envtools
  # 第一项 = 新 DTS 的 compatible 第一字段（运行时 board_name）
  # 第二项 = hanwckf 老固件 board name，允许从老固件直接 sysupgrade 过来
  # 第三项 = JimLee1996 rebase 仓库同硬件 board name，允许互刷 sysupgrade
  # 第四项 = 上游最终合并的 zhao,7981r128 board name，允许互刷 sysupgrade
  SUPPORTED_DEVICES := sx,7981r128 mediatek,mt7981-spim-snand-7981r128 \
                       mediatek,zhao-7981r128-d zhao,7981r128
  KERNEL_IN_UBI := 1
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  IMAGE_SIZE := 114688k
  UBINIZE_OPTS := -E 5
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += sx_7981r128
FILOGIC_EOF
        echo "[device-add]   设备条目已追加到 filogic.mk"
    else
        echo "[device-add]   设备条目已存在，跳过追加"
    fi

    # 3. 注入 board.d/02_network 配置
    #    端口分配：lan1（千兆）→ br-lan，lan2（2.5G EN8801SC）→ WAN
    #    eth1（SFP 笼）通过 uci-defaults 配置为 wan2
    #    没有这个配置，OpenWrt 会走默认 *) 分支，端口不能正常工作
    BOARD_NETWORK="target/linux/mediatek/filogic/base-files/etc/board.d/02_network"
    if [ -f "$BOARD_NETWORK" ] && ! grep -q 'sx,7981r128' "$BOARD_NETWORK"; then
        awk '
            /^mediatek_setup_interfaces\(\)$/ { in_interfaces = 1 }
            in_interfaces && !done && /^\t\*\)$/ {
                print "\tsx,7981r128)"
                print "\t\tucidef_set_interfaces_lan_wan \"lan1\" \"lan2\""
                print "\t\t;;"
                done = 1
            }
            /^mediatek_setup_macs\(\)$/ { in_macs = 1 }
            in_macs && !mac_done && /^\tesac$/ {
                print "\tsx,7981r128)"
                print "\t\tlan_mac=$(mtd_get_mac_binary factory 0x04)"
                print "\t\t[ -n \"$lan_mac\" ] || lan_mac=$(mtd_get_mac_binary Factory 0x04)"
                print "\t\twan_mac=$(macaddr_add \"$lan_mac\" 1)"
                print "\t\tlabel_mac=$lan_mac"
                print "\t\t;;"
                mac_done = 1
            }
            { print }
        ' "$BOARD_NETWORK" > "$BOARD_NETWORK.new" && mv "$BOARD_NETWORK.new" "$BOARD_NETWORK"
        echo "[device-add]   02_network 接口/MAC case 已注入"
    fi

    # 4. 注入 board.d/01_leds 配置
    BOARD_LEDS="target/linux/mediatek/filogic/base-files/etc/board.d/01_leds"
    if [ -f "$BOARD_LEDS" ] && ! grep -q 'sx,7981r128' "$BOARD_LEDS"; then
        awk '
            !done && /^esac$/ {
                print "\tsx,7981r128)"
                print "\t\tucidef_set_led_netdev \"lan2\" \"LAN2\" \"green:lan\" \"lan2\" \"link tx rx\""
                print "\t\tucidef_set_led_netdev \"sfp\" \"SFP\" \"green:wan\" \"eth1\" \"link tx rx\""
                print "\t\tucidef_set_led_netdev \"wlan2g\" \"WIFI2G\" \"green:wlan-2ghz\" \"phy0-ap0\" \"link tx rx\""
                print "\t\tucidef_set_led_netdev \"wlan5g\" \"WIFI5G\" \"green:wlan-5ghz\" \"phy1-ap0\" \"link tx rx\""
                print "\t\t;;"
                done = 1
            }
            { print }
        ' "$BOARD_LEDS" > "$BOARD_LEDS.new" && mv "$BOARD_LEDS.new" "$BOARD_LEDS"
        echo "[device-add]   01_leds case 已注入"
    fi

    # 5. 注入首次启动 uci-defaults
    #    - 启用 WiFi（radio0/radio1 默认 disabled=1）
    #    - 添加 wan2 接口（eth1，SFP 笼，DHCP）并加入防火墙 WAN zone
    mkdir -p package/base-files/files/etc/uci-defaults
    cat > package/base-files/files/etc/uci-defaults/98_sx_7981r128_init.sh << 'UCI_EOF'
#!/bin/sh
# 仅对 sx,7981r128 执行
[ "$(cat /tmp/sysinfo/board_name 2>/dev/null)" = "sx,7981r128" ] || exit 0

. /lib/functions.sh
. /lib/functions/system.sh

# --- WiFi：启用双频射频 ---
uci set wireless.radio0.disabled=0
uci set wireless.radio1.disabled=0
uci commit wireless

# --- 网络：wan6（2.5G 主WAN，lan2，IPv6）+ wan2/wan2_6（SFP 笼，eth1）---
# wan6 不由 ucidef_set_interfaces_lan_wan 自动创建，需手动补上
uci set network.wan.metric=10
uci set network.wan6=interface
uci set network.wan6.device=lan2
uci set network.wan6.proto=dhcpv6
uci set network.wan6.metric=10
uci set network.wan2=interface
uci set network.wan2.device=eth1
uci set network.wan2.proto=dhcp
uci set network.wan2.metric=20
uci set network.wan2_6=interface
uci set network.wan2_6.device=eth1
uci set network.wan2_6.proto=dhcpv6
uci set network.wan2_6.metric=20
base_mac=$(mtd_get_mac_binary factory 0x04 2>/dev/null)
[ -n "$base_mac" ] || base_mac=$(mtd_get_mac_binary Factory 0x04 2>/dev/null)
if [ -n "$base_mac" ]; then
    uci set network.wan2.macaddr="$(macaddr_add "$base_mac" 2)"
fi
uci commit network

# --- 防火墙：将 wan2 加入 WAN zone ---
wan_zone_idx=""
i=0
while uci get "firewall.@zone[$i]" >/dev/null 2>&1; do
    if [ "$(uci get firewall.@zone[$i].name 2>/dev/null)" = "wan" ]; then
        wan_zone_idx=$i
        break
    fi
    i=$((i + 1))
done
if [ -n "$wan_zone_idx" ]; then
    uci add_list firewall.@zone[$wan_zone_idx].network=wan2
    uci add_list firewall.@zone[$wan_zone_idx].network=wan2_6
    uci commit firewall
fi

exit 0
UCI_EOF
    chmod +x package/base-files/files/etc/uci-defaults/98_sx_7981r128_init.sh
    echo "[device-add]   uci-defaults 98_sx_7981r128_init.sh 已注入"

    # 6. 注入 lib/upgrade/platform.sh 配置
    #    参考 zhao_7981-r128-dsa-mtkuboot：sysupgrade-tar + ubi NAND 升级路径
    PLATFORM_SH="target/linux/mediatek/filogic/base-files/lib/upgrade/platform.sh"
    if [ -f "$PLATFORM_SH" ] && ! grep -q 'sx,7981r128' "$PLATFORM_SH"; then
        awk '
            /^platform_do_upgrade\(\) \{/ { in_upgrade = 1 }
            in_upgrade && !upgrade_done && /^\t(jiorouter,ax6000-jidu6101|ruijie,rg-x30e-pro)\)$/ {
                print "\tsx,7981r128|\\"
                upgrade_done = 1
            }
            /^platform_check_image\(\) \{/ { in_upgrade = 0; in_check = 1 }
            in_check && !check_done && /^\tnradio,c8-668gl\)$/ {
                print "\tsx,7981r128|\\"
                check_done = 1
            }
            { print }
        ' "$PLATFORM_SH" > "$PLATFORM_SH.new" && mv "$PLATFORM_SH.new" "$PLATFORM_SH"
        echo "[device-add]   platform.sh sysupgrade case 已注入"
    fi

    # 7. 注入 uboot-envtools 配置
    #    上游 zhao,7981r128 使用 /dev/mtd1 0x0 0x20000 0x20000，sx 同硬件沿用。
    if [ -f "$SX7981_UBOOT_ENVTOOLS" ] && ! grep -q 'sx,7981r128' "$SX7981_UBOOT_ENVTOOLS"; then
        awk '
            !done && /^[[:space:]]*zhao,7981r128\)$/ {
                print "\tsx,7981r128|\\"
                done = 1
            }
            !done && /^[[:space:]]*zbtlink,zbt-z8103ax\)$/ {
                sub(/\)$/, "|\\")
                print
                print "\tsx,7981r128)"
                done = 1
                next
            }
            { print }
        ' "$SX7981_UBOOT_ENVTOOLS" > "$SX7981_UBOOT_ENVTOOLS.new" && mv "$SX7981_UBOOT_ENVTOOLS.new" "$SX7981_UBOOT_ENVTOOLS"
        echo "[device-add]   uboot-envtools case 已注入"
    fi

    # 8. 注入 mtk-smp 配置
    #    MTK rebase 源存在该文件时，加入 7981R128 到 MT7981 WHNAT/SMP 分支。
    if [ -f "$SX7981_SMP_SH" ] && ! grep -q 'sx,7981r128' "$SX7981_SMP_SH"; then
        awk '
            !done && /^\t\*7981\*\)$/ {
                print "\tzhao,7981r128 |\\"
                print "\tsx,7981r128 |\\"
                done = 1
            }
            { print }
        ' "$SX7981_SMP_SH" > "$SX7981_SMP_SH.new" && mv "$SX7981_SMP_SH.new" "$SX7981_SMP_SH"
        echo "[device-add]   mtk-smp case 已注入"
    fi

    echo "[device-add] 完成"
    echo "================================================================"
fi

# =======================================================
# [section: package-sources] 安装和更新软件包
# =======================================================
UPDATE_PACKAGE() {
	local PKG_NAME=$1
	local PKG_REPO=$2
	local PKG_BRANCH=$3
	local PKG_SPECIAL=$4
	
	read -ra PKG_NAMES <<< "$PKG_NAME"
	for NAME in "${PKG_NAMES[@]}"; do
		find feeds/luci/ feeds/packages/ package/ -maxdepth 3 -type d \( -name "$NAME" -o -name "luci-*-$NAME" \) -exec rm -rf {} + 2>/dev/null
	done
	
	if [[ $PKG_REPO == http* ]]; then
		local REPO_NAME=$(basename "$PKG_REPO" .git)
	else
		local REPO_NAME=$(echo "$PKG_REPO" | cut -d '/' -f 2)
		PKG_REPO="https://github.com/$PKG_REPO.git"
	fi
	
	if ! git clone --depth=1 --single-branch --branch "$PKG_BRANCH" "$PKG_REPO" "package/$REPO_NAME"; then
		echo "错误: 克隆仓库失败 $PKG_REPO"
		exit 1
	fi
	
	case "$PKG_SPECIAL" in
		"pkg")
			for NAME in "${PKG_NAMES[@]}"; do
				find "./package/$REPO_NAME" -maxdepth 3 -type d \( -name "$NAME" -o -name "luci-*-$NAME" \) -print0 | \
					xargs -0 -I {} cp -rf {} ./package/ 2>/dev/null
			done
			rm -rf "./package/$REPO_NAME/"
			;;
		"name")
			rm -rf "./package/$PKG_NAME"
			mv -f "./package/$REPO_NAME" "./package/$PKG_NAME"
			;;
	esac
}

UPDATE_PACKAGE "luci-app-poweroff" "esirplayground/luci-app-poweroff" "main"
#UPDATE_PACKAGE "openwrt-gecoosac" "ysuolmai/openwrt-gecoosac" "main"
# gecoosac 上游作者 (kiss19776) 经常覆盖同名 release asset，PKG_HASH 跟不上
# 把 PKG_HASH:=xxxxx 改成 PKG_HASH:=skip 跳过校验
#if [ -f ./package/openwrt-gecoosac/gecoosac/Makefile ]; then
#    sed -i 's/^PKG_HASH:=.*/PKG_HASH:=skip/' ./package/openwrt-gecoosac/gecoosac/Makefile
#    echo "[diy] openwrt-gecoosac PKG_HASH 设为 skip"
#fi
UPDATE_PACKAGE "luci-app-openlist2" "sbwml/luci-app-openlist2" "main"

#small-package
UPDATE_PACKAGE "xray-core xray-plugin dns2tcp dns2socks haproxy hysteria \
        naiveproxy v2ray-core v2ray-geodata v2ray-geoview v2ray-plugin \
        tuic-client chinadns-ng ipt2socks tcping trojan-plus simple-obfs shadowsocksr-libev \
        luci-app-passwall smartdns luci-app-smartdns v2dat mosdns luci-app-mosdns \
        taskd luci-lib-xterm luci-lib-taskd luci-app-passwall2 luci-app-ssr-plus shadowsocks-libev \
        luci-app-store quickstart luci-app-quickstart luci-app-istorex luci-app-cloudflarespeedtest \
        netdata luci-app-netdata \
        docker shadowsocks-rust" "kenzok8/jell" "main" "pkg"

# tcping 0.5 intermittently fails when its two objects are built in parallel.
# Keep this package serial while the rest of the firmware build stays parallel.
TCPING_MAKEFILE="package/tcping/Makefile"
if [ -f "$TCPING_MAKEFILE" ]; then
	sed -i 's/^PKG_BUILD_PARALLEL:=1$/PKG_BUILD_PARALLEL:=0/' "$TCPING_MAKEFILE"
fi

# jell's lucky package only installs the binary, while its LuCI app expects
# /etc/config/lucky and /etc/init.d/lucky. Import the maintained pair together.
UPDATE_PACKAGE "lucky luci-app-lucky" "sirpdboy/luci-app-lucky" "main" "pkg"

# Keep the installed app visible even if Lucky's UCI config is temporarily
# missing or the LuCI menu cache is built before first-boot defaults run.
LUCKY_MENU="package/luci-app-lucky/root/usr/share/luci/menu.d/luci-app-lucky.json"
if [ -f "$LUCKY_MENU" ]; then
    python3 - "$LUCKY_MENU" <<'PYEOF'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as source:
    menu = json.load(source)

menu.get("admin/services/lucky", {}).get("depends", {}).pop("uci", None)

with open(path, "w", encoding="utf-8") as target:
    json.dump(menu, target, ensure_ascii=False, indent=4)
    target.write("\n")
PYEOF
fi

# Self-maintained packages. Remove feed sources, installed feed links and
# third-party collection copies before cloning our package collection.
find feeds/luci feeds/packages package -maxdepth 5 \
    \( -type d -o -type l \) \
    \( -name frp -o -name luci-app-frp -o -name luci-app-frpc -o -name luci-app-frps \
       -o -name ddns-go -o -name luci-app-ddns-go \
       -o -name luci-app-adguardhome -o -name luci-theme-shadcn \
       -o -name sing-box -o -name luci-app-homeproxy \
       -o -name luci-app-nginx -o -name tailscale \
       -o -name luci-app-tailscale -o -name luci-app-tailscale-community \
       -o -name dockerd -o -name luci-app-dockerman \) \
    -prune -exec rm -rf {} + 2>/dev/null
rm -rf package/ysuolmai-packages
if ! git clone --depth=1 --single-branch --branch main \
    https://github.com/ysuolmai/openwrt-packages.git \
    package/ysuolmai-packages; then
    echo "[diy] 错误：克隆自维护软件包仓库失败"
    exit 1
fi
echo "[diy] self-maintained package collection installed"

# Go 1.27 made encoding/json/v2 the default and removed the experimental
# SkipFunc/DiscardUnknownMembers APIs. The sing-box snapshot still depends on
# the pre-release go-json-experiment aliases, so build it with the supported
# compatibility switch until that dependency is refreshed upstream.
SING_BOX_MAKEFILE="package/ysuolmai-packages/sing-box/Makefile"
if [ -f "$SING_BOX_MAKEFILE" ] && \
   grep -q 'golang-package\.mk' "$SING_BOX_MAKEFILE" && \
   ! grep -q 'GOEXPERIMENT=nojsonv2' "$SING_BOX_MAKEFILE"; then
    sed -i '/golang-package\.mk/a GO_PKG_BUILD_VARS += GOEXPERIMENT=nojsonv2' "$SING_BOX_MAKEFILE"
    echo "[diy] enabled Go JSON v1 compatibility for sing-box"
fi

#speedtest
UPDATE_PACKAGE "luci-app-netspeedtest" "https://github.com/sbwml/openwrt_pkgs.git" "main" "pkg"
UPDATE_PACKAGE "speedtest-cli" "https://github.com/sbwml/openwrt_pkgs.git" "main" "pkg"

UPDATE_PACKAGE "openwrt-podman" "https://github.com/breeze303/openwrt-podman" "main"
UPDATE_PACKAGE "luci-app-quickfile" "https://github.com/sbwml/luci-app-quickfile" "main"
sed -i 's|$(INSTALL_BIN) $(PKG_BUILD_DIR)/quickfile-$(ARCH_PACKAGES) $(1)/usr/bin/quickfile|$(INSTALL_BIN) $(PKG_BUILD_DIR)/quickfile-aarch64_generic $(1)/usr/bin/quickfile|' package/luci-app-quickfile/quickfile/Makefile

# bandix
UPDATE_PACKAGE "openwrt-bandix" "timsaya/openwrt-bandix" "main"
UPDATE_PACKAGE "luci-app-bandix" "timsaya/luci-app-bandix" "main"

# =======================================================
# [section: image-and-config] 固件标识和基础配置
# =======================================================
WRT_IP="192.168.1.1"
WRT_NAME="FWRT"
WRT_WIFI="FWRT"

sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js")

WIFI_SH=$(find ./target/linux/{mediatek/filogic,qualcommax}/base-files/etc/uci-defaults/ -type f -name "*set-wireless.sh")
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
if [ -f "$WIFI_SH" ]; then
	sed -i "s/BASE_SSID='.*'/BASE_SSID='$WRT_SSID'/g" $WIFI_SH
	sed -i "s/BASE_WORD='.*'/BASE_WORD='$WRT_WORD'/g" $WIFI_SH
elif [ -f "$WIFI_UC" ]; then
	sed -i "s/ssid='.*'/ssid='$WRT_SSID'/g" $WIFI_UC
	sed -i "s/key='.*'/key='$WRT_WORD'/g" $WIFI_UC
	sed -i "s/country='.*'/country='CN'/g" $WIFI_UC
	sed -i "s/encryption='.*'/encryption='psk2+ccmp'/g" $WIFI_UC
fi

CFG_FILE="./package/base-files/files/bin/config_generate"
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $CFG_FILE
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" $CFG_FILE


if [[ $WRT_CONFIG == *"EMMC"* ]]; then
    keep_pattern="\(redmi_ax5-jdcloud\|jdcloud_re-ss-01\|jdcloud_re-cs-07\)=y$"
else
    keep_pattern="\(redmi_ax5\|qihoo_360v6\|redmi_ax5-jdcloud\|zn_m2\|jdcloud_re-ss-01\|jdcloud_re-cs-07\)=y$"
fi

# 使用标准的 "is not set" 注释，避免后面的 make defconfig 重新启用默认设备。
sed -i "/^CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_/{
    /$keep_pattern/! s/^CONFIG_\([^=]*\)=.*/# CONFIG_\1 is not set/
}" ./.config


# MTK 设备白名单——只保留这里列出的设备，其他 MEDIATEK-WIFI-{YES,NO}.txt
# 里的设备一律显式设为 not set，避免 make defconfig 恢复默认设备。
# 想多编几个设备就往 mtk_keep 里加（用 \| 分隔），名字对应
# Config/MEDIATEK-WIFI-*.txt 里 CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_xxx 的 xxx。
mtk_keep="\(sx_7981r128\|nokia_ea0326gmp\|cmcc_rax3000m\)=y$"

sed -i "/^CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_/{
    /$mtk_keep/! s/^CONFIG_\([^=]*\)=.*/# CONFIG_\1 is not set/
}" ./.config

# cmcc_rax3000m 只编译 NAND 版本。上游公共定义同时带入 eMMC overlay、GPT
# 和 eMMC/NAND 两套 artifact；这里在源码进入 image 规则前重写该设备定义，
# 避免没有 eMMC BL2 时仍生成 eMMC 文件。
if [[ "$WRT_CONFIG" == "MEDIATEK-"* || "$WRT_CONFIG" == "MTK-"* ]]; then
    MTK_FILOGIC_MK="target/linux/mediatek/image/filogic.mk"
    if [ -f "$MTK_FILOGIC_MK" ]; then
        awk '
            /^define Device\/cmcc_rax3000m$/ {
                in_rax3000m = 1
                skip_rax3000m = 0
                print
                next
            }
            /^define Device\/cmcc_rax3000me$/ {
                in_rax3000m = 0
                skip_rax3000m = 0
                print
                next
            }
            in_rax3000m && /\$\(call Device\/cmcc_rax3000m_common\)/ {
                print
                print "  DEVICE_DTS_OVERLAY := mt7981b-cmcc-rax3000m-nand"
                print "  ARTIFACTS := nand-preloader.bin nand-bl31-uboot.fip"
                print "  ARTIFACT/nand-preloader.bin := mt7981-bl2 spim-nand-ddr4"
                print "  ARTIFACT/nand-bl31-uboot.fip := mt7981-bl31-uboot cmcc_rax3000m-nand"
                skip_rax3000m = 1
                next
            }
            in_rax3000m && /^endef$/ {
                in_rax3000m = 0
                skip_rax3000m = 0
                print
                next
            }
            in_rax3000m && skip_rax3000m { next }
            { print }
        ' "$MTK_FILOGIC_MK" > "$MTK_FILOGIC_MK.new" && mv "$MTK_FILOGIC_MK.new" "$MTK_FILOGIC_MK"
        echo "[mtk-fix] cmcc_rax3000m 已限制为 NAND artifact"
    fi

    # U-Boot/TFA 的默认条件会按设备名同时启用 cmcc_rax3000m 的 eMMC/NAND
    # 变体；显式注释 eMMC，保留 NAND 引导链。
    set_config "PACKAGE_u-boot-mt7981_cmcc_rax3000m-nand" y || exit 1
    set_config "PACKAGE_u-boot-mt7981_cmcc_rax3000m-emmc" unset || exit 1
    set_config "PACKAGE_trusted-firmware-a-mt7981-spim-nand-ddr4" y || exit 1
    set_config "PACKAGE_trusted-firmware-a-mt7981-emmc-ddr4" unset || exit 1
fi

# =======================================================
# [section: target-policy] 按构建类型筛选目标设备和功能
# =======================================================
keywords_to_delete=(
    "uugamebooster" "luci-app-wol" "luci-i18n-wol-zh-cn" "CONFIG_TARGET_INITRAMFS" "ddns" "luci-app-advancedplus" "mihomo" "nikki"
    "smartdns" "luci-app-partexp" "luci-app-upnp" "diskmanager"
)

[[ $WRT_CONFIG == *"WIFI-NO"* ]] && keywords_to_delete+=("usb" "wpad" "hostapd")
[[ $WRT_CONFIG != *"EMMC"* ]] && keywords_to_delete+=("samba" "autosamba" "disk")

for keyword in "${keywords_to_delete[@]}"; do
    sed -i "/$keyword/d" ./.config
done

# shadcn is the only supported LuCI theme.
sed -i '/^CONFIG_PACKAGE_luci-theme-/d' ./.config

# =======================================================
# [upstream-fix] hostapd MU-EDCA patch requires CONFIG_IEEE80211AX
# No-WiFi builds can still compile wpad/hostapd as a dependency, but the
# hidden DRIVER_11AX_SUPPORT symbol is not selected by any WiFi driver.
# The upstream MU-EDCA patch then touches struct hostapd_config.he_mu_edca
# while CONFIG_IEEE80211AX is disabled, which breaks wpad-full-openssl.
# =======================================================
if [[ "$WRT_CONFIG" == *"WIFI-NO"* ]]; then
    HOSTAPD_PATCH_DIR="package/network/services/hostapd/patches"
    if [ -d "$HOSTAPD_PATCH_DIR" ]; then
        while IFS= read -r -d '' HOSTAPD_PATCH; do
            if grep -q "he_mu_edca" "$HOSTAPD_PATCH"; then
                echo "[upstream-fix] remove no-AX hostapd MU-EDCA patch: $HOSTAPD_PATCH"
                rm -f "$HOSTAPD_PATCH"
            fi
        done < <(find "$HOSTAPD_PATCH_DIR" -type f -name "*.patch" -print0)
    fi
fi

# =======================================================
# [section: package-config] 按构建类型整理软件包配置
# =======================================================
provided_config_lines=(
    "CONFIG_PACKAGE_luci-app-zerotier=y"
    "CONFIG_PACKAGE_luci-i18n-zerotier-zh-cn=y"
    "CONFIG_PACKAGE_luci-app-poweroff=y"
    "CONFIG_PACKAGE_luci-i18n-poweroff-zh-cn=y"
    "CONFIG_PACKAGE_cpufreq=y"
    "CONFIG_PACKAGE_luci-app-cpufreq=y"
    "CONFIG_PACKAGE_luci-i18n-cpufreq-zh-cn=y"
    "CONFIG_PACKAGE_luci-app-ttyd=y"
    "CONFIG_PACKAGE_luci-i18n-ttyd-zh-cn=y"
    "CONFIG_PACKAGE_ttyd=y"
    "CONFIG_PACKAGE_luci-app-homeproxy=y"
    "CONFIG_PACKAGE_luci-i18n-homeproxy-zh-cn=y"
    "CONFIG_PACKAGE_ddns-go=y"
    "CONFIG_PACKAGE_luci-app-ddns-go=y"
    "CONFIG_PACKAGE_luci-i18n-ddns-go-zh-cn=y"
    "CONFIG_PACKAGE_nano=y"
    "CONFIG_PACKAGE_luci-app-vlmcsd=y"
    "CONFIG_COREMARK_OPTIMIZE_O3=y"
    "CONFIG_COREMARK_ENABLE_MULTITHREADING=y"
    "CONFIG_COREMARK_NUMBER_OF_THREADS=6"
    "CONFIG_PACKAGE_luci-app-filetransfer=y"
    "CONFIG_PACKAGE_openssh-sftp-server=y"
    "CONFIG_PACKAGE_luci-app-frp=y"
    "CONFIG_OPKG_USE_CURL=y"
    "CONFIG_PACKAGE_opkg=y"
    "CONFIG_USE_APK=n"
    "CONFIG_PACKAGE_luci-app-cifs-mount=y"
    "CONFIG_PACKAGE_kmod-fs-cifs=y"
    "CONFIG_PACKAGE_cifsmount=y"
	"CONFIG_PACKAGE_luci-theme-shadcn=y"
    #"CONFIG_PACKAGE_luci-app-openclash=y"
)

if [[ $WRT_CONFIG == *"WIFI-NO"* ]]; then
    provided_config_lines+=("CONFIG_PACKAGE_hostapd-common=n" "CONFIG_PACKAGE_wpad-openssl=n")
fi

if [[ "$WRT_CONFIG" != *"EMMC"* && "$WRT_CONFIG" == *"WIFI-NO"* ]]; then
    sed -i 's/\s*kmod-[^ ]*usb[^ ]*\s*\\\?//g' ./target/linux/qualcommax/Makefile
    echo "已删除 Makefile 中的 USB 相关 package"
fi

[[ $WRT_CONFIG == *"EMMC"* ]] && provided_config_lines+=(
    "CONFIG_PACKAGE_moontvplus=y"
    "CONFIG_PACKAGE_luci-app-moontvplus=y"
    "CONFIG_PACKAGE_luci-app-nginx=y"
    "CONFIG_PACKAGE_luci-i18n-nginx-zh-cn=y"
    "CONFIG_PACKAGE_luci-app-adguardhome=y"
    "CONFIG_PACKAGE_luci-i18n-adguardhome-zh-cn=y"
    "CONFIG_PACKAGE_luci-app-netspeedtest=y"
    "CONFIG_PACKAGE_tailscale=y"
    "CONFIG_PACKAGE_luci-app-tailscale-community=y"
    "CONFIG_PACKAGE_luci-i18n-tailscale-community-zh-cn=y"
	"CONFIG_PACKAGE_luci-app-ssr-plus=y"
	"CONFIG_PACKAGE_shadowsocks-rust=y"
	"CONFIG_PACKAGE_shadowsocksr-libev=y"
	"CONFIG_PACKAGE_shadowsocks-libev=y"
    "CONFIG_PACKAGE_luci-app-gecoosac=y"
	"CONFIG_PACKAGE_luci-app-passwall=y"
    "CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Shadowsocks_Libev_Client=y"
    "CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Shadowsocks_Libev_Server=y"
    "CONFIG_PACKAGE_luci-app-passwall_INCLUDE_ShadowsocksR_Libev_Client=n"
    "CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Simple_Obfs=n"
    "CONFIG_PACKAGE_luci-app-passwall_INCLUDE_SingBox=n"
    "CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Trojan_Plus=n"
    "CONFIG_PACKAGE_luci-app-passwall_INCLUDE_V2ray_Plugin=n"
    # luci-app-docker installs a competing S25docker service which starts
    # dockerd without the maintained daemon configuration.
    "CONFIG_PACKAGE_luci-app-docker=n"
    "CONFIG_PACKAGE_luci-i18n-docker-zh-cn=n"
    "CONFIG_PACKAGE_luci-app-dockerman=y"
    "CONFIG_PACKAGE_luci-i18n-dockerman-zh-cn=y"
    "CONFIG_PACKAGE_luci-app-openlist2=y"
    "CONFIG_PACKAGE_luci-i18n-openlist2-zh-cn=y"
    "CONFIG_PACKAGE_ip6tables-nft=y"
    "CONFIG_PACKAGE_htop=y"
    "CONFIG_PACKAGE_tcpdump=y"
    "CONFIG_PACKAGE_openssl-util=y"
    "CONFIG_PACKAGE_qrencode=y"
    "CONFIG_PACKAGE_smartmontools-drivedb=y"
    "CONFIG_PACKAGE_default-settings=y"
    "CONFIG_PACKAGE_default-settings-chn=y"
    "CONFIG_PACKAGE_kmod-br-netfilter=y"
    "CONFIG_PACKAGE_kmod-nf-ipt6=y"
    "CONFIG_PACKAGE_kmod-nf-ipvs=y"
    "CONFIG_PACKAGE_kmod-nf-nat6=y"
    "CONFIG_PACKAGE_kmod-dummy=y"
    "CONFIG_PACKAGE_kmod-veth=y"
    "CONFIG_PACKAGE_luci-app-samba4=y"
    "CONFIG_PACKAGE_libuver-zero=y"
    "CONFIG_PACKAGE_kmod-sched-tbf=y"
    "CONFIG_PACKAGE_kmod-sched-htb=y"
    "CONFIG_PACKAGE_tc-full=y"
    "CONFIG_PACKAGE_kmod-sched-netem=y"
	#"CONFIG_PACKAGE_nikki=y"
	#"CONFIG_PACKAGE_luci-app-nikki=y"
	#"CONFIG_PACKAGE_luci-i18n-nikki-zh-cn=y"
	#"CONFIG_PACKAGE_luci-app-lucky=y"
	#"CONFIG_PACKAGE_lucky=y"
    # =========================
    # [Travel Router Tools]
    # =========================
    "CONFIG_PACKAGE_bind-dig=y"
    "CONFIG_PACKAGE_bind-host=y"
    "CONFIG_PACKAGE_drill=y"
    "CONFIG_PACKAGE_dnslookup=y"

    "CONFIG_PACKAGE_iperf3=y"
    "CONFIG_PACKAGE_mtr=y"
    "CONFIG_PACKAGE_arping=y"
    "CONFIG_PACKAGE_ethtool=y"

    "CONFIG_PACKAGE_screen=y"
    "CONFIG_PACKAGE_tmux=y"

    "CONFIG_PACKAGE_tree=y"
    "CONFIG_PACKAGE_file=y"
    "CONFIG_PACKAGE_bc=y"

    "CONFIG_PACKAGE_watchcat=y"
    "CONFIG_PACKAGE_luci-app-watchcat=y"

    "CONFIG_PACKAGE_vnstat2=y"

    "CONFIG_PACKAGE_curl=y"

    "CONFIG_PACKAGE_lsblk=y"
)

if [[ "$WRT_CONFIG" == *"WIFI-YES"* ]]; then
    provided_config_lines+=(
        # TravelMate 只用于带 WiFi 的固件，WIFI-NO 固件不加入这两个包。
        "CONFIG_PACKAGE_travelmate=y"
        "CONFIG_PACKAGE_luci-app-travelmate=y"
    )
fi

[[ $WRT_CONFIG == "IPQ"* ]] && provided_config_lines+=(
    "CONFIG_PACKAGE_sqm-scripts-nss=y"
    "CONFIG_PACKAGE_luci-app-sqm=y"
    "CONFIG_PACKAGE_luci-i18n-sqm-zh-cn=y"
)
[[ $WRT_CONFIG == *"MEDIATEK"* || $WRT_CONFIG == *"MTK"* || $WRT_CONFIG == *"7981"* ]] && provided_config_lines+=(
    "CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_sx_7981r128=y"
)

for line in "${provided_config_lines[@]}"; do
    config_line="${line#CONFIG_}"
    config_name="${config_line%%=*}"
    config_value="${config_line#*=}"
    set_config "$config_name" "$config_value" || exit 1
done

# =======================================================
# [pkg-fix] 替换 Makefile 中的 +kmod-iptables 直接依赖为 +kmod-nf-ipt
# =======================================================
echo "================================================================"
echo "[pkg-fix] 替换 Makefile 中的 +kmod-iptables 依赖为 +kmod-nf-ipt"

_affected=$(grep -rl "+kmod-iptables" package/ feeds/ 2>/dev/null || true)
if [ -n "$_affected" ]; then
    _total=$(echo "$_affected" | wc -l)
    echo "[pkg-fix] 发现 $_total 个文件依赖 kmod-iptables，前 15 个:"
    echo "$_affected" | head -15 | sed 's/^/  - /'
    while IFS= read -r _mk; do
        sed -i -E 's/\+kmod-iptables([^a-zA-Z0-9_-]|$)/+kmod-nf-ipt\1/g' "$_mk"
    done <<< "$_affected"
    _remain=$(grep -rlE "\+kmod-iptables([^a-zA-Z0-9_-]|$)" package/ feeds/ 2>/dev/null | wc -l)
    echo "[pkg-fix] 替换完成，残留 $_remain 处 (应为 0)"
else
    echo "[pkg-fix] 没有文件依赖 kmod-iptables (已是干净状态)"
fi

set_config "PACKAGE_kmod-iptables" unset || exit 1
echo "================================================================"

# =======================================================
# [pkg-fix-2] 替换 Makefile 中 +iptables 间接依赖为 +iptables-nft
# =======================================================
echo "================================================================"
echo "[pkg-fix-2] 替换 Makefile 中的 +iptables 间接依赖为 +iptables-nft"

_affected2=$(grep -rlE '\+iptables([^-a-zA-Z0-9_]|$)' package/ feeds/ 2>/dev/null \
    | xargs grep -lv 'PKG_NAME:=iptables' 2>/dev/null || true)

if [ -n "$_affected2" ]; then
    _total2=$(echo "$_affected2" | wc -l)
    echo "[pkg-fix-2] 发现 $_total2 个文件依赖 +iptables，前 15 个:"
    echo "$_affected2" | head -15 | sed 's/^/  - /'
    while IFS= read -r _mk; do
        sed -i -E 's/\+iptables([^-a-zA-Z0-9_]|$)/+iptables-nft\1/g' "$_mk"
    done <<< "$_affected2"
    _remain2=$(grep -rlE '\+iptables([^-a-zA-Z0-9_]|$)' package/ feeds/ 2>/dev/null \
        | xargs grep -lv 'PKG_NAME:=iptables' 2>/dev/null | wc -l)
    echo "[pkg-fix-2] 替换完成，残留 $_remain2 处 (应为 0)"
else
    echo "[pkg-fix-2] 没有文件依赖 +iptables (已是干净状态)"
fi

set_config "PACKAGE_iptables" unset || exit 1
echo "================================================================"

# =======================================================
# [pkg-fix-3] 清除 kmod-iptables 的文件安装，消除与 kmod-nf-ipt 的冲突
# 根因：内核 CONFIG_IP_NF_IPTABLES=m 会让构建系统自动选中 kmod-iptables，
# 绕过 Makefile 依赖链。让 kmod-iptables 变成不安装任何文件的空壳包，
# 由 kmod-nf-ipt 提供相同的 .ko，功能不受影响，冲突消失。
# =======================================================
echo "================================================================"
echo "[pkg-fix-3] 清除 kmod-iptables FILES/AUTOLOAD，消除与 kmod-nf-ipt 的文件冲突"

KMOD_IPT_MK=$(grep -rl "define KernelPackage/iptables$" package/ target/ 2>/dev/null | head -n 1)
if [ -n "$KMOD_IPT_MK" ]; then
    echo "[pkg-fix-3] 找到定义文件: $KMOD_IPT_MK"
    python3 - "$KMOD_IPT_MK" << 'PYEOF'
import sys

filename = sys.argv[1]
with open(filename) as f:
    lines = f.readlines()

result = []
in_ipt_block = False
skip_continuation = False

for line in lines:
    stripped = line.strip()

    if stripped == 'define KernelPackage/iptables':
        in_ipt_block = True
        result.append(line)
        continue

    if in_ipt_block and stripped == 'endef':
        in_ipt_block = False
        result.append(line)
        continue

    if in_ipt_block:
        if skip_continuation:
            if not stripped.endswith('\\'):
                skip_continuation = False
            continue
        if stripped.startswith('FILES:=') or stripped.startswith('AUTOLOAD:='):
            if stripped.endswith('\\'):
                skip_continuation = True
            continue

    result.append(line)

with open(filename, 'w') as f:
    f.writelines(result)

print(f'[pkg-fix-3] 完成: {filename}')
PYEOF
else
    echo "[pkg-fix-3] 未找到 kmod-iptables 定义文件，跳过"
fi
echo "================================================================"


# =======================================================
# [section: filesystem-customization] 固件文件和主题定制
# =======================================================
find ./ -name "cascade.css" -exec sed -i 's/#5e72e4/#31A1A1/g; s/#483d8b/#31A1A1/g' {} \;
find ./ -name "dark.css" -exec sed -i 's/#5e72e4/#31A1A1/g; s/#483d8b/#31A1A1/g' {} \;
find ./ -name "cascade.less" -exec sed -i 's/#5e72e4/#31A1A1/g; s/#483d8b/#31A1A1/g' {} \;
find ./ -name "dark.less" -exec sed -i 's/#5e72e4/#31A1A1/g; s/#483d8b/#31A1A1/g' {} \;

install -Dm755 "${GITHUB_WORKSPACE}/Scripts/99_ttyd-nopass.sh" "package/base-files/files/etc/uci-defaults/99_ttyd-nopass"
install -Dm755 "${GITHUB_WORKSPACE}/Scripts/98_zerotier_tailscale_coexist.sh" "package/base-files/files/etc/uci-defaults/98_zerotier_tailscale_coexist"
install -Dm644 "${GITHUB_WORKSPACE}/Scripts/vpn-overlay-isolation.nft" "package/base-files/files/usr/share/nftables.d/ruleset-post/vpn-overlay-isolation.nft"
install -Dm644 "${GITHUB_WORKSPACE}/Scripts/zerotier.local.conf" "package/base-files/files/etc/zerotier.local.conf"
install -Dm755 "${GITHUB_WORKSPACE}/Scripts/99-distfeeds.conf" "package/emortal/default-settings/files/99-distfeeds.conf"
sed -i '/define Package\/default-settings\/install/a \
\t$(INSTALL_DIR) $(1)/etc\n\t$(INSTALL_DATA) ./files/99-distfeeds.conf $(1)/etc/99-distfeeds.conf' \
package/emortal/default-settings/Makefile

sed -i "/exit 0/i\\
[ -f \'/etc/99-distfeeds.conf\' ] && mv \'/etc/99-distfeeds.conf\' \'/etc/opkg/distfeeds.conf\'\n\
sed -ri \'/check_signature/s@^[^#]@#&@\' /etc/opkg.conf\n" "package/emortal/default-settings/files/99-default-settings"

install -Dm755 "${GITHUB_WORKSPACE}/Scripts/99_dropbear_setup.sh" "package/base-files/files/etc/uci-defaults/99_dropbear_setup"

find ./ -name "getifaddr.c" -exec sed -i 's/return 1;/return 0;/g' {} \;

if [ -f ./package/v2ray-geodata/Makefile ]; then
    sed -i 's/VER)-\$(PKG_RELEASE)/VER)-r\$(PKG_RELEASE)/g' ./package/v2ray-geodata/Makefile
fi
if [ -f ./package/luci-lib-taskd/Makefile ]; then
    sed -i 's/>=1\.0\.3-1/>=1\.0\.3-r1/g' ./package/luci-lib-taskd/Makefile
fi
if [ -f ./package/luci-app-openclash/Makefile ]; then
    sed -i '/^PKG_VERSION:=/a PKG_RELEASE:=1' ./package/luci-app-openclash/Makefile
fi
if [ -f ./package/luci-app-quickstart/Makefile ]; then
    sed -i -E 's/PKG_VERSION:=([0-9]+\.[0-9]+\.[0-9]+)-([0-9]+)/PKG_VERSION:=\1\nPKG_RELEASE:=\2/' ./package/luci-app-quickstart/Makefile
fi
if [ -f ./package/luci-app-store/Makefile ]; then
    sed -i -E 's/PKG_VERSION:=([0-9]+\.[0-9]+\.[0-9]+)-([0-9]+)/PKG_VERSION:=\1\nPKG_RELEASE:=\2/' ./package/luci-app-store/Makefile
fi

RUST_FILE=$(find ./feeds/packages/ -maxdepth 3 -type f -wholename "*/rust/Makefile")
if [ -f "$RUST_FILE" ]; then
    echo " "
    sed -i 's/ci-llvm=true/ci-llvm=false/g' $RUST_FILE
    patch $RUST_FILE ${GITHUB_WORKSPACE}/Scripts/rust-makefile.patch
    echo "rust has been fixed!"
fi


# =======================================================
# [section: docker] 使用自维护的原生 nftables Dockerman，并补齐 luci-lib-docker
# =======================================================
echo "Handling Docker dependencies..."

rm -rf package/feeds/luci/luci-app-dockerman
rm -rf package/feeds/luci/luci-lib-docker
rm -rf package/luci-app-dockerman
rm -rf package/luci-lib-docker

if [ ! -f package/ysuolmai-packages/luci-app-dockerman/Makefile ]; then
    echo "错误: 自维护 luci-app-dockerman 未找到"
    exit 1
fi

echo "Cloning luci-lib-docker..."
if ! git clone --depth 1 https://github.com/lisaac/luci-lib-docker.git temp_libdocker; then
    echo "错误：克隆 luci-lib-docker 失败"
    exit 1
fi
if [ -d "temp_libdocker/collections/luci-lib-docker" ]; then
    if ! mv temp_libdocker/collections/luci-lib-docker package/luci-lib-docker; then
        echo "错误：安装 luci-lib-docker 失败"
        exit 1
    fi
else
    if ! mv temp_libdocker package/luci-lib-docker; then
        echo "错误：安装 luci-lib-docker 失败"
        exit 1
    fi
fi
rm -rf temp_libdocker

./scripts/feeds install ttyd
./scripts/feeds install luci-lib-docker

# =======================================================
# 修复 Docker 引擎 (dockerd) 和 CLI (docker)
# =======================================================
echo "Fetching latest Docker version..."
_MOBY_TAG=$(curl -sf https://api.github.com/repos/moby/moby/releases/latest | \
    python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])")
DOCKER_VER=$(echo "$_MOBY_TAG" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')

if [ -z "$DOCKER_VER" ]; then
    echo "警告: 无法获取 Docker 最新版本，回退到 29.5.2"
    DOCKER_VER="29.5.2"
    DOCKERD_COMMIT="568f755"
    DOCKER_CLI_COMMIT="79eb04c"
else
    echo "Latest Docker version: $DOCKER_VER (tag: $_MOBY_TAG)"
    DOCKERD_COMMIT=$(curl -sf "https://api.github.com/repos/moby/moby/commits?sha=${_MOBY_TAG}&per_page=1" | \
        python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['sha'][:7] if isinstance(d,list) and d else '')")
    DOCKER_CLI_COMMIT=$(curl -sf "https://api.github.com/repos/docker/cli/commits?sha=v${DOCKER_VER}&per_page=1" | \
        python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['sha'][:7] if isinstance(d,list) and d else '')")
    if [ -z "$DOCKERD_COMMIT" ] || [ -z "$DOCKER_CLI_COMMIT" ]; then
        echo "警告: 无法获取 commit hash，回退到已知值"
        DOCKERD_COMMIT="568f755"
        DOCKER_CLI_COMMIT="79eb04c"
    fi
fi
echo "Docker: $DOCKER_VER | dockerd: $DOCKERD_COMMIT | cli: $DOCKER_CLI_COMMIT"

dockerd_makefile=$(find package/ feeds/ -name Makefile | xargs grep -lE "^PKG_NAME:=dockerd$" | head -n 1)
docker_makefile=$(find package/ feeds/ -name Makefile | xargs grep -lE "^PKG_NAME:=docker$" | head -n 1)

if [ -f "$dockerd_makefile" ]; then
    echo "Processing dockerd Makefile at: $dockerd_makefile"
    sed -i "s/^PKG_VERSION:=.*/PKG_VERSION:=$DOCKER_VER/" "$dockerd_makefile"
    sed -i "s/PKG_GIT_SHORT_COMMIT:=.*/PKG_GIT_SHORT_COMMIT:=$DOCKERD_COMMIT/g" "$dockerd_makefile"
    sed -i 's/^PKG_HASH:=.*/PKG_HASH:=skip/' "$dockerd_makefile"
    sed -i '/define Build\/Prepare/,/endef/c\define Build\/Prepare\n\t$(Build\/Prepare\/Default)\nendef' "$dockerd_makefile"
    sed -i 's/^\t$(call EnsureVendored/#\t$(call EnsureVendored/g' "$dockerd_makefile"
fi

if [ -f "$docker_makefile" ]; then
    echo "Processing docker CLI Makefile at: $docker_makefile"
    sed -i "s/^PKG_VERSION:=.*/PKG_VERSION:=$DOCKER_VER/" "$docker_makefile"
    sed -i "s/PKG_GIT_SHORT_COMMIT:=.*/PKG_GIT_SHORT_COMMIT:=$DOCKER_CLI_COMMIT/g" "$docker_makefile"
    sed -i 's/^PKG_HASH:=.*/PKG_HASH:=skip/' "$docker_makefile"
    sed -i '/define Build\/Prepare/,/endef/c\define Build\/Prepare\n\t$(Build\/Prepare\/Default)\nendef' "$docker_makefile"
fi

echo "All Docker compilation fixes applied successfully!"


if ! grep -q "CMAKE_POLICY_VERSION_MINIMUM" include/cmake.mk; then
    echo 'CMAKE_OPTIONS += -DCMAKE_POLICY_VERSION_MINIMUM=3.5' >> include/cmake.mk
fi

# =======================================================
# [section: toolchain-refresh] 升级 Go 工具链
# =======================================================
# 升级 golang 到支持 go.mod >= 1.26 的版本
WRT_DIR=$(pwd)
GO_TMP_DIR=/tmp/openwrt-packages
rm -rf feeds/packages/lang/golang
rm -rf "$GO_TMP_DIR"
if ! git clone https://github.com/openwrt/packages --depth=1 --filter=blob:none --sparse "$GO_TMP_DIR"; then
    echo "错误：克隆 OpenWrt packages 仓库失败"
    exit 1
fi
if ! (cd "$GO_TMP_DIR" && git sparse-checkout set lang/golang); then
    echo "错误：配置 Go sparse-checkout 失败"
    exit 1
fi
if ! cp -r "$GO_TMP_DIR/lang/golang" "$WRT_DIR/feeds/packages/lang/golang"; then
    echo "错误：安装 Go feed 失败"
    exit 1
fi
cd "$WRT_DIR"
GO_DEFAULT_VERSION=$(sed -n 's/^GO_DEFAULT_VERSION:=//p' feeds/packages/lang/golang/golang-values.mk | head -n 1)
rm -rf package/feeds/packages/golang*
./scripts/feeds update -i packages
./scripts/feeds install -f golang "golang${GO_DEFAULT_VERSION}"
rm -rf staging_dir/hostpkg/lib/go-* \
       staging_dir/hostpkg/lib/go-cross \
       staging_dir/hostpkg/stamp/.golang* \
       staging_dir/hostpkg/stamp/.go* \
       build_dir/hostpkg/go-* \
       build_dir/hostpkg/golang*

# =======================================================
# [kernel-fix] 修复 Linux 6.18 新增 Kconfig 选项
# 导致 syncconfig 在 CI 非交互环境下卡死报错
# 遇到新的 (NEW) 选项，往 NEW_OPTS 数组里加一行即可
# =======================================================
NEW_OPTS=(
    "PERSISTENT_HUGE_ZERO_FOLIO"
    "NO_PAGE_MAPCOUNT"
)

echo "[kernel-fix] 开始修复新增 Kconfig 选项..."

while IFS= read -r -d '' cfg; do
    for opt in "${NEW_OPTS[@]}"; do
        if ! grep -q "CONFIG_${opt}" "$cfg"; then
            echo "# CONFIG_${opt} is not set" >> "$cfg"
            echo "[kernel-fix] 已追加 # CONFIG_${opt} is not set -> $cfg"
        fi
    done
done < <(find target/linux/generic/ target/linux/qualcommax/ -name "config-*" -print0 2>/dev/null)

echo "[kernel-fix] 完成。"

# =======================================================
# [qca-fix] 清理 GL-AX1800 DTS 中失效的 MAC NVMEM 引用
# 当前 qualcommax 源码的 ipq6018-ess.dtsi 没有提供 macaddr_wan/
# macaddr_lan 标签，但 ipq6000-gl-ax1800.dts 仍引用它们，导致 DTC
# 在所有包含 GL-AX1800 镜像的 QCA 构建中直接失败。
# =======================================================
QCA_AX1800_DTS=$(find target/linux/qualcommax -type f \
    -name 'ipq6000-gl-ax1800.dts' -print -quit 2>/dev/null)
if [ -n "$QCA_AX1800_DTS" ] && \
   grep -qE 'nvmem-cells = <&macaddr_(wan|lan)>;' "$QCA_AX1800_DTS" && \
   ! grep -RqsE '^[[:space:]]*macaddr_(wan|lan):' \
       target/linux/qualcommax/dts target/linux/qualcommax/files 2>/dev/null; then
    sed -i -E \
        -e '/^[[:space:]]*nvmem-cells = <&macaddr_(wan|lan)>;/d' \
        -e '/^[[:space:]]*nvmem-cell-names = "mac-address";/d' \
        "$QCA_AX1800_DTS"
    echo "[qca-fix] 已移除 GL-AX1800 中无对应 provider 的 macaddr NVMEM 引用"
fi

# =======================================================
# [ebpf] eBPF 构建专项处理
# 仅当 WRT_CONFIG 含 "EBPF" 时执行，不影响其他任何构建
# =======================================================
if [[ "$WRT_CONFIG" == *"EBPF"* ]]; then
    echo "================================================================"
    echo "[ebpf] 开始 eBPF 构建专项配置..."

    MTK_EBPF_HONK_ONLY=false
    if [[ "$WRT_CONFIG" == "MTK-EBPF-"* || "$WRT_CONFIG" == "MEDIATEK-EBPF-"* ]]; then
        MTK_EBPF_HONK_ONLY=true
    fi

    if [[ "$MTK_EBPF_HONK_ONLY" != true ]]; then
        # 0. 从独立仓库拉取 dae + luci-app-dae 包
        #    仓库：https://github.com/ysuolmai/luci-app-dae
        #    这两个包独立维护，便于版本升级和复用，不污染主仓库
        DAE_FEED_DIR="/tmp/luci-app-dae-feed"
        rm -rf "$DAE_FEED_DIR"
        if ! git clone --depth=1 https://github.com/ysuolmai/luci-app-dae "$DAE_FEED_DIR"; then
            echo "[dae] 错误：clone luci-app-dae 失败"
            exit 1
        fi
        # 上游 ImmortalWrt 的 feeds 自带 dae / luci-app-dae / luci-app-daed，
        # 与我们的同名会撞，buildroot 可能编了上游那份。像 UPDATE_PACKAGE 一样
        # 把 feeds 和 package 里所有同名包先全删干净，再放我们的。
        find feeds/ package/ -maxdepth 4 -type d \
            \( -name dae -o -name luci-app-dae -o -name luci-app-daed \) \
            -exec rm -rf {} + 2>/dev/null
        if ! cp -rf "$DAE_FEED_DIR/dae" package/ || \
           ! cp -rf "$DAE_FEED_DIR/luci-app-dae" package/; then
            echo "[dae] 错误：安装 luci-app-dae 软件包失败"
            exit 1
        fi
        echo "[dae] 已从 ysuolmai/luci-app-dae 拉取 dae + luci-app-dae"
    else
        rm -rf /tmp/luci-app-dae-feed
        find feeds/ package/ -maxdepth 4 \
            \( -type d -o -type l \) \
            \( -name dae -o -name luci-app-dae -o -name luci-app-daed \) \
            -exec rm -rf {} + 2>/dev/null
        for DAE_PACKAGE in dae luci-app-dae luci-app-daed; do
            set_config "PACKAGE_${DAE_PACKAGE}" remove || exit 1
        done
        echo "[ebpf] MTK-EBPF 仅启用 Honk，已移除 dae / luci-app-dae / luci-app-daed"
    fi

    # 1. 拉取 Honk 完整 feed，保留仓库根目录供 SDK 工具链配置使用
    #    Honk 是 eBPF 透明代理引擎，只在 EBPF 固件启用。
    HONK_FEED_DIR="package/openwrt-honk"
    rm -rf "$HONK_FEED_DIR"
    find feeds/ package/ -maxdepth 5 \
        \( -type d -o -type l \) \
        \( -name honk -o -name luci-app-honk -o -name luci-app-honk-legacy \) \
        -exec rm -rf {} + 2>/dev/null

    if ! git clone --depth=1 --single-branch --branch main \
        https://github.com/breeze303/openwrt-honk.git "$HONK_FEED_DIR"; then
        echo "[honk] 错误：clone openwrt-honk 失败"
        exit 1
    fi

    # OpenWrt 的 /var 通常是指向 /tmp 的运行时链接，不能在包 staging
    # 阶段把它当普通目录合并。Honk 初始化脚本会在首次启动时创建
    # /var/share/honk，因此这里只移除 Makefile 的预创建动作。
    HONK_MAKEFILE="$HONK_FEED_DIR/honk/Makefile"
    if [ -f "$HONK_MAKEFILE" ]; then
        # /var 是 OpenWrt staging 中的运行时链接，不能由包安装成目录。
        # 同时处理 INSTALL_DIR 与单独的 chmod 行，兼容上游换行或排版变化。
        awk '
            /^[[:space:]]*chmod[[:space:]]+0700[[:space:]]+\$\(1\)\/var\/share\/honk[[:space:]]*$/ { next }
            {
                gsub(/[[:space:]]+\$\(1\)\/var\/share\/honk/, "")
                print
            }
        ' "$HONK_MAKEFILE" > "$HONK_MAKEFILE.new" && mv "$HONK_MAKEFILE.new" "$HONK_MAKEFILE"

        if grep -qF '$(1)/var/share/honk' "$HONK_MAKEFILE"; then
            echo "[honk] 错误：Makefile 仍会在 staging 阶段创建 /var/share/honk"
            exit 1
        fi
        echo "[honk] 已移除 /var/share/honk 的 staging 预创建，改由 init 脚本运行时创建"
    fi

    # 旧版 Honk 通过 geo.lock.json 自己下载 Geo 资源；新版改为依赖
    # OpenWrt 的 v2ray-geoip/v2ray-geosite 包，不再携带 geo.lock.json。
    if [ -f "$HONK_FEED_DIR/locks/geo.lock.json" ]; then
        mapfile -t HONK_GEO_ASSETS < <(
            python3 - "$HONK_FEED_DIR/locks/geo.lock.json" <<'PYEOF'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    lock = json.load(source)

for asset in lock.get("assets", []):
    print("\t".join((asset["cachePath"], asset["sourceUrl"], asset["sha256"])))
PYEOF
        )

        if [ "${#HONK_GEO_ASSETS[@]}" -eq 0 ]; then
            echo "[honk] 错误：geo.lock.json 未包含任何 Geo 资源"
            exit 1
        fi

        for HONK_GEO_ASSET in "${HONK_GEO_ASSETS[@]}"; do
            IFS=$'\t' read -r HONK_GEO_PATH HONK_GEO_URL HONK_GEO_SHA256 <<< "$HONK_GEO_ASSET"
            HONK_GEO_FILE="$HONK_FEED_DIR/$HONK_GEO_PATH"
            mkdir -p "$(dirname "$HONK_GEO_FILE")"

            echo "[honk] 下载并校验 $(basename "$HONK_GEO_FILE")"
            if ! curl --fail --location --retry 5 --retry-all-errors --retry-delay 2 \
                --output "$HONK_GEO_FILE" "$HONK_GEO_URL"; then
                echo "[honk] 错误：下载 Geo 资源失败 $HONK_GEO_URL"
                exit 1
            fi
            if ! printf '%s  %s\n' "$HONK_GEO_SHA256" "$HONK_GEO_FILE" | sha256sum -c -; then
                echo "[honk] 错误：Geo 资源校验失败 $HONK_GEO_FILE"
                exit 1
            fi
        done
    elif [ -f "$HONK_FEED_DIR/honk/Makefile" ] && \
         grep -qE 'v2ray-geoip|v2ray-geosite' "$HONK_FEED_DIR/honk/Makefile"; then
        echo "[honk] 当前版本使用 OpenWrt 的 v2ray-geoip/v2ray-geosite，无需下载旧版 Geo 锁定资源"
    else
        echo "[honk] 错误：未找到 geo.lock.json 或新版 Geo feed 依赖"
        exit 1
    fi

    # 按 Honk 官方 feed 方式安装包，保留完整 clone 供 WRT-CORE 读取
    # BPF Rust/toolchain 锁定信息。
    HONK_FEEDS_CONF=""
    if [ -f feeds.conf ]; then
        HONK_FEEDS_CONF="feeds.conf"
    elif [ -f feeds.conf.default ]; then
        HONK_FEEDS_CONF="feeds.conf.default"
    fi
    if [ -z "$HONK_FEEDS_CONF" ]; then
        echo "[honk] 错误：找不到 OpenWrt feeds 配置文件"
        exit 1
    fi
    sed -i -E '/^[[:space:]]*src-[^[:space:]]+[[:space:]]+honk([[:space:]]|$)/d' "$HONK_FEEDS_CONF"
    printf 'src-link honk %s\n' "$HONK_FEED_DIR" >> "$HONK_FEEDS_CONF"
    if ! ./scripts/feeds update honk || \
       ! ./scripts/feeds install -f -p honk honk luci-app-honk; then
        echo "[honk] 错误：注册或安装 Honk feed 失败"
        exit 1
    fi

    # Honk 新版 LuCI 页面依赖 honk 引擎；legacy 页面保留在仓库中但不打入固件。
    for HONK_PACKAGE in honk luci-app-honk; do
        set_config "PACKAGE_${HONK_PACKAGE}" y || exit 1
    done
    echo "[honk] 已启用 honk + luci-app-honk"

    # 2. 移除 openclash 和 passwall（eBPF/Honk 是唯一透明代理，避免冲突）
    sed -i '/openclash/d; /passwall/d' .config
    echo "[ebpf] 已从 .config 移除 openclash / passwall 相关行"

    # 3. 扩大 eMMC 设备内核分区
    #    eBPF 包含字节码，编译产物比普通代理大，默认 6144k 不够
    image_file='./target/linux/qualcommax/image/ipq60xx.mk'
    if [ -f "$image_file" ]; then
        sed -i "/^define Device\/emmc-common/,/^endef/ s/KERNEL_SIZE := 6144k/KERNEL_SIZE := 12288k/" "$image_file"
        sed -i "/^define Device\/jdcloud_re-ss-01/,/^endef/ { /KERNEL_SIZE := 6144k/s//KERNEL_SIZE := 12288k/ }" "$image_file"
        sed -i "/^define Device\/jdcloud_re-cs-02/,/^endef/ { /KERNEL_SIZE := 6144k/s//KERNEL_SIZE := 12288k/ }" "$image_file"
        sed -i "/^define Device\/jdcloud_re-cs-07/,/^endef/ { /KERNEL_SIZE := 6144k/s//KERNEL_SIZE := 12288k/ }" "$image_file"
        sed -i "/^define Device\/link_nn6000-common/,/^endef/ { /KERNEL_SIZE := 6144k/s//KERNEL_SIZE := 12288k/ }" "$image_file"
        sed -i "/^define Device\/linksys_mr/,/^endef/ { /KERNEL_SIZE := 8192k/s//KERNEL_SIZE := 12288k/ }" "$image_file"
        echo "[ebpf] eMMC 内核分区已扩大至 12288k"
    fi

    echo "[ebpf] eBPF 构建专项配置完成"
    echo "================================================================"
fi
