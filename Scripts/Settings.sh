#!/bin/bash

#修改默认主题
sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $(find ./feeds/luci/collections/ -type f -name "Makefile")
#修改默认WIFI名
sed -i "s/\.ssid=.*/\.ssid=$WRT_WIFI/g" $(find ./package/kernel/mac80211/ ./package/network/config/ -type f -name "mac80211.*")

CFG_FILE="./package/base-files/files/bin/config_generate"
#修改默认IP地址
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $CFG_FILE
#修改默认主机名
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" $CFG_FILE
#修改默认时区
sed -i "s/timezone='.*'/timezone='CST-8'/g" $CFG_FILE
sed -i "/timezone='.*'/a\\\t\t\set system.@system[-1].zonename='Asia/Shanghai'" $CFG_FILE

if [[ $WRT_REPO == *"lede"* ]]; then
	LEDE_FILE=$(find ./package/lean/autocore/ -type f -name "index.htm")
	#修改默认时间格式
	sed -i 's/os.date()/os.date("%Y-%m-%d %H:%M:%S %A")/g' $LEDE_FILE
	#添加编译日期标识
	sed -i "s/(\(<%=pcdata(ver.luciversion)%>\))/\1 \/ $WRT_CI-$WRT_DATE/g" $LEDE_FILE
else
	#修改immortalwrt.lan关联IP
	sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js")
	#添加编译日期标识
	sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ $WRT_CI-$WRT_DATE')/g" $(find ./feeds/luci/modules/luci-mod-status/ -type f -name "10_system.js")
fi

#配置文件修改
echo "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y" >> ./.config
echo "CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y" >> ./.config

#手动调整的插件
if [ -n "$WRT_PACKAGE" ]; then
	echo "$WRT_PACKAGE" >> ./.config
fi

#高通平台锁定512M内存
if [[ $WRT_TARGET == *"IPQ"* ]]; then
	echo "CONFIG_ATH11K_MEM_PROFILE_1G=n" >> ./.config
	echo "CONFIG_ATH11K_MEM_PROFILE_512M=y" >> ./.config
fi

#科学插件设置
if [[ $WRT_REPO == *"lede"* ]]; then
	echo "CONFIG_PACKAGE_luci-app-openclash=y" >> ./.config
	echo "CONFIG_PACKAGE_luci-app-passwall=y" >> ./.config
	echo "CONFIG_PACKAGE_luci-app-ssr-plus=y" >> ./.config
	echo "CONFIG_PACKAGE_luci-app-turboacc=y" >> ./.config
else
	echo "CONFIG_PACKAGE_luci=y" >> ./.config
	echo "CONFIG_LUCI_LANG_zh_Hans=y" >> ./.config
	echo "CONFIG_PACKAGE_luci-app-homeproxy=y" >> ./.config
fi



keywords_to_delete=(
"passwall"
"v2ray"
"sing-box"
"ddns"
"SINGBOX"
"redmi_ax5=y"
"cmcc_rm2"
"xiaomi_ax3600"
"xiaomi_ax9000"
"xiaomi_ax1800"
"cmiot_ax18"
"glinet_gl-ax1800"
"glinet_gl-axt1800"
"jdcloud_ax6600"
"linksys_mr7350"
"uugamebooster"
"luci-app-homeproxy"
"CONFIG_TARGET_INITRAMFS"
)

if [[ $WRT_TARGET == *"WIFI-NO"* ]]; then
	keywords_to_delete+=("usb")
 	keywords_to_delete+=("samba")
  	keywords_to_delete+=("autosamba")
fi

for line in "${keywords_to_delete[@]}"; do
    sed -i "/$line/d" ./.config
done


provided_config_lines=(
"CONFIG_PACKAGE_luci-app-ssr-plus=y"
"CONFIG_PACKAGE_luci-i18n-ssr-plus-zh-cn=y"
"CONFIG_PACKAGE_luci-app-zerotier=y"
"CONFIG_PACKAGE_luci-i18n-zerotier-zh-cn=y"
"CONFIG_PACKAGE_luci-app-adguardhome=y"
"CONFIG_PACKAGE_luci-i18n-adguardhome-zh-cn=y"
"CONFIG_PACKAGE_luci-app-ddns-go=y"
"CONFIG_PACKAGE_luci-i18n-ddns-go-zh-cn=y"
"CONFIG_PACKAGE_luci-app-poweroff=y"
"CONFIG_PACKAGE_luci-i18n-poweroff-zh-cn=y"
"CONFIG_PACKAGE_cpufreq=y"
"CONFIG_PACKAGE_luci-app-cpufreq=y"
"CONFIG_PACKAGE_luci-i18n-cpufreq-zh-cn=y"
"CONFIG_PACKAGE_luci-app-ttyd=y"
"CONFIG_PACKAGE_luci-i18n-ttyd-zh-cn=y"
"CONFIG_PACKAGE_ttyd=y"
"CONFIG_TARGET_INITRAMFS=n"
#"CONFIG_PACKAGE_luci-app-vlmcsd=y"
#"CONFIG_PACKAGE_vlmcsd=y"
#"CONFIG_PACKAGE_luci-i18n-vlmcsd-zh-cn=y"
)

# Append lines to the .config file
for line in "${provided_config_lines[@]}"; do
    echo "$line" >> ./.config
done

new_WRT_IP="192.168.1.1"

sed -i "s/192\.168\.[0-9]*\.[0-9]*/$new_WRT_IP/g" $CFG_FILE

#修改默认主机名
sed -i "s/hostname='.*'/hostname='FishWRT'/g" $CFG_FILE
#修改默认时区
sed -i "/timezone='.*'/a\\\t\t\set system.@system[-1].zonename='Asia/Singapore'" $CFG_FILE


./scripts/feeds update -a
./scripts/feeds install -a

rm -rf ./package/feeds/packages/shadowsocks-rust
cp -r ./package/helloworld/shadowsocks-rust ./package/feeds/packages/shadowsocks-rust
