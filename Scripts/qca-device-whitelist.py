#!/usr/bin/env python3
"""Apply/check the IPQ60xx device whitelist after make defconfig."""
import re
import sys
from pathlib import Path

# Device profile, eMMC, WiFi. Ordinary firmware includes eMMC devices too.
DEVICES = (
    ("cmiot_ax18", False, True),
    ("zn_m2", False, True),
    ("redmi_ax5", False, True),
    ("redmi_ax5-jdcloud", True, True),
    ("jdcloud_re-cs-07", True, False),
    ("jdcloud_re-ss-01", True, True),
    ("qihoo_360v6", False, True),
)
PREFIX = "CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_"


def run(mode, variant, path):
    if mode not in ("apply", "check") or not re.fullmatch(
        r"IPQ60XX-(?:EBPF-EMMC-|EMMC-)?WIFI-(?:YES|NO)", variant
    ):
        raise ValueError(f"Unsupported mode/profile: {mode} {variant}")
    expected = {
        PREFIX + device
        for device, emmc, wifi in DEVICES
        if ("EMMC" not in variant or emmc)
        and (not variant.endswith("WIFI-YES") or wifi)
    }
    lines = path.read_text().splitlines()
    available = set(re.findall(
        r"^(?:# )?(CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_[\w-]+)(?:=| is not set)",
        "\n".join(lines), re.M,
    ))
    missing = expected - available
    if missing:
        raise ValueError(f"Device profiles missing from defconfig: {sorted(missing)}")
    if mode == "apply":
        # Explicitly disable every other profile, including newly added devices.
        lines = [line for line in lines if not re.match(
            r"(?:# )?CONFIG_TARGET_(?:DEVICE_|ALL_PROFILES(?:=| ))", line
        )]
        lines.append("# CONFIG_TARGET_ALL_PROFILES is not set")
        lines.extend(
            f"{symbol}=y" if symbol in expected else f"# {symbol} is not set"
            for symbol in sorted(available)
        )
        path.write_text("\n".join(lines) + "\n")
    else:
        actual = set(re.findall(r"^(CONFIG_TARGET_DEVICE_[\w-]+)=y$", "\n".join(lines), re.M))
        if actual != expected or "CONFIG_TARGET_ALL_PROFILES=y" in lines:
            raise ValueError(
                f"Whitelist mismatch: extra={sorted(actual - expected)}, "
                f"missing={sorted(expected - actual)}"
            )
    print(f"{variant}: {mode} whitelist OK ({len(expected)} devices)")


if __name__ == "__main__":
    try:
        run(sys.argv[1], sys.argv[2], Path(sys.argv[3]))
    except (ValueError, OSError) as error:
        sys.exit(f"::error::{error}")
