#!/bin/bash

#修改默认主题
sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $(find ./feeds/luci/collections/ -type f -name "Makefile")
#修改immortalwrt.lan关联IP
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js")
#添加编译日期标识
sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ $WRT_CI-$WRT_DATE')/g" $(find ./feeds/luci/modules/luci-mod-status/ -type f -name "10_system.js")

WIFI_SH="./package/base-files/files/etc/uci-defaults/990_set-wireless.sh"
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
if [ -f "$WIFI_SH" ]; then
	#修改WIFI名称
	sed -i "s/BASE_SSID='.*'/BASE_SSID='$WRT_SSID'/g" $WIFI_SH
	#修改WIFI密码
	sed -i "s/BASE_WORD='.*'/BASE_WORD='$WRT_WORD'/g" $WIFI_SH
elif [ -f "$WIFI_UC" ]; then
	#修改WIFI名称
	sed -i "s/ssid='.*'/ssid='$WRT_SSID'/g" $WIFI_UC
	#修改WIFI密码
	sed -i "s/key='.*'/key='$WRT_WORD'/g" $WIFI_UC
	#修改WIFI地区
	sed -i "s/country='.*'/country='CN'/g" $WIFI_UC
	#修改WIFI加密
	sed -i "s/encryption='.*'/encryption='psk2+ccmp'/g" $WIFI_UC
fi

CFG_FILE="./package/base-files/files/bin/config_generate"
#修改默认IP地址
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $CFG_FILE
#修改默认主机名
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" $CFG_FILE

#配置文件修改
echo "CONFIG_PACKAGE_luci=y" >> ./.config
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> ./.config
echo "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y" >> ./.config
echo "CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y" >> ./.config

#手动调整的插件
if [ -n "$WRT_PACKAGE" ]; then
	echo "$WRT_PACKAGE" >> ./.config
fi

#高通平台调整
if [[ $WRT_TARGET == *"IPQ"* ]]; then
	#取消nss相关feed
	echo "CONFIG_FEED_nss_packages=n" >> ./.config
	echo "CONFIG_FEED_sqm_scripts_nss=n" >> ./.config
fi



#######################################
#DIY
#######################################
WRT_IP="192.168.1.1"
WRT_NAME="FWRT"
WRT_WIFI="FWRT"
#修改immortalwrt.lan关联IP
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js")
#修改默认WIFI名
sed -i "s/\.ssid=.*/\.ssid=$WRT_WIFI/g" $(find ./package/kernel/mac80211/ ./package/network/config/ -type f -name "mac80211.*")

#修改默认IP地址
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $CFG_FILE
#修改默认主机名
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" $CFG_FILE


if [[ $WRT_SOURCE == *"lede"* ]]; then
	echo "CONFIG_PACKAGE_luci-theme-design=y" >> ./.config
 	echo "CONFIG_PACKAGE_luci-app-design-config=y" >> ./.config
  	sed -i "/$WRT_THEME/d" ./.config
fi

#补齐依赖
sudo -E apt-get -y install $(curl -fsSL is.gd/depends_ubuntu_2204)

keywords_to_delete=(
    "xiaomi_ax3600" "xiaomi_ax9000" "xiaomi_ax1800" "glinet" "jdcloud_ax6600" "kucat"
    "mr7350" "uugamebooster" "luci-app-wol" "luci-i18n-wol-zh-cn" "CONFIG_TARGET_INITRAMFS" "ddns" "tailscale" "luci-app-advancedplus"
)

[[ $WRT_TARGET == *"WIFI-NO"* ]] && keywords_to_delete+=("usb" "wpad" "hostapd")
[[ $WRT_TARGET != *"EMMC"* ]] && keywords_to_delete+=("samba" "autosamba" "jdcloud_ax1800-pro" "jdcloud_re-ss-01" "redmi_ax5-jdcloud" "disk")
[[ $WRT_TARGET == *"EMMC"* ]] && keywords_to_delete+=("cmiot_ax18" "qihoo_v6" "qihoo_360v6" "redmi_ax5=y" "zn_m2")

for keyword in "${keywords_to_delete[@]}"; do
    sed -i "/$keyword/d" ./.config
done

# Configuration lines to append to .config
provided_config_lines=(
    "CONFIG_PACKAGE_luci-app-zerotier=y"
    "CONFIG_PACKAGE_luci-i18n-zerotier-zh-cn=y"
    "CONFIG_PACKAGE_luci-app-adguardhome=y"
    "CONFIG_PACKAGE_luci-i18n-adguardhome-zh-cn=y"
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
    "CONFIG_PACKAGE_luci-app-ddns-go=y"
    "CONFIG_PACKAGE_luci-i18n-ddns-go-zh-cn=y"
    "CONFIG_PACKAGE_libminiupnpc=y"
    "CONFIG_PACKAGE_luci-app-upnp=y"
    "CONFIG_PACKAGE_luci-i18n-upnp-zh-cn=y"
    "CONFIG_PACKAGE_miniupnpd-nftables=y"
    #"CONFIG_BUSYBOX_CONFIG_LSUSB=n"
    "CONFIG_PACKAGE_luci-app-alist=y"
    "CONFIG_PACKAGE_luci-i18n-alist-zh-cn=y"
)

[[ $WRT_TARGET == *"WIFI-NO"* ]] && provided_config_lines+=("CONFIG_PACKAGE_hostapd-common=n" "CONFIG_PACKAGE_wpad-openssl=n")
if [[ $WRT_TAG == *"WIFI-NO"* ]]; then
    provided_config_lines+=(
        "CONFIG_PACKAGE_hostapd-common=n"
        "CONFIG_PACKAGE_wpad-openssl=n"
    )
#else
    #provided_config_lines+=(
    #    "CONFIG_PACKAGE_kmod-usb-net=y"
    #    "CONFIG_PACKAGE_kmod-usb-net-rndis=y"
    #    "CONFIG_PACKAGE_kmod-usb-net-cdc-ether=y"
    #    "CONFIG_PACKAGE_usbutils=y"
    #)
fi


[[ $WRT_TARGET == *"EMMC"* ]] && provided_config_lines+=(
    "CONFIG_PACKAGE_luci-app-diskman=y"
    "CONFIG_PACKAGE_luci-i18n-diskman-zh-cn=y"
    "CONFIG_PACKAGE_luci-app-docker=y"
    "CONFIG_PACKAGE_luci-i18n-docker-zh-cn=y"
    "CONFIG_PACKAGE_luci-app-dockerman=y"
    "CONFIG_PACKAGE_luci-i18n-dockerman-zh-cn=y"
)

# Append configuration lines to .config
for line in "${provided_config_lines[@]}"; do
    echo "$line" >> .config
done


#./scripts/feeds update -a
#./scripts/feeds install -a

find ./ -name "cascade.css" -exec sed -i 's/#5e72e4/#6fa49a/g; s/#483d8b/#6fa49a/g' {} \;
find ./ -name "dark.css" -exec sed -i 's/#5e72e4/#6fa49a/g; s/#483d8b/#6fa49a/g' {} \;

find ./ -name "getifaddr.c" -exec sed -i 's/return 1;/return 0;/g' {} \;
#find ./ -type d -name 'luci-app-ddns-go' -exec sh -c '[ -f "$1/Makefile" ] && sed -i "/config\/ddns-go/d" "$1/Makefile"' _ {} \;
#find ./ -type d -name "luci-app-ddns-go" -exec sh -c 'f="{}/Makefile"; [ -f "$f" ] && echo "\ndefine Package/\$(PKG_NAME)/install\n\trm -f \$(1)/etc/config/ddns-go\n\t\$(call InstallDev,\$(1))\nendef\n" >> "$f"' \;
#find ./ -type d -name "ddns-go" -exec sh -c 'f="{}/Makefile"; [ -f "$f" ] && sed -i "/\$(INSTALL_BIN).*\/ddns-go.init.*\/etc\/init.d\/ddns-go/d" "$f"' \;
rm -rf ./feeds/packages/net/ddns-go;







