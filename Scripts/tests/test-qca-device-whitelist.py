#!/usr/bin/env python3
"""Check all six variants and reject devices restored by defconfig."""
import importlib.util
import tempfile
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "whitelist", Path(__file__).resolve().parents[1] / "qca-device-whitelist.py"
)
whitelist = importlib.util.module_from_spec(spec)
spec.loader.exec_module(whitelist)
prefix = whitelist.PREFIX
ordinary = {"cmiot_ax18", "zn_m2", "redmi_ax5", "qihoo_360v6"}
emmc = {"redmi_ax5-jdcloud", "jdcloud_re-ss-01", "jdcloud_re-cs-07"}

with tempfile.TemporaryDirectory() as root:
    config = Path(root) / ".config"
    for group in ("", "EMMC-", "EBPF-EMMC-"):
        for wifi in ("YES", "NO"):
            variant = f"IPQ60XX-{group}WIFI-{wifi}"
            expected = emmc | (ordinary if not group else set())
            if wifi == "YES":
                expected = expected - {"jdcloud_re-cs-07"}
            # Simulate defaults/cache/upstream enabling every device.
            initial = [f"{prefix}{device}=y" for device in ordinary | emmc | {"new_upstream_device"}]
            initial += ["CONFIG_TARGET_ALL_PROFILES=y", "CONFIG_PACKAGE_luci=y"]
            config.write_text("\n".join(initial) + "\n")
            whitelist.run("apply", variant, config)
            whitelist.run("check", variant, config)
            lines = config.read_text().splitlines()
            assert {line for line in lines if line.startswith(prefix) and line.endswith("=y")} == {
                f"{prefix}{device}=y" for device in expected
            }
            assert "CONFIG_PACKAGE_luci=y" in lines
            result = config.read_text()
            for invalid in (
                result + f"{prefix}new_upstream_device=y\n",
                result.replace(f"{prefix}redmi_ax5-jdcloud=y\n", ""),
                result + "CONFIG_TARGET_ALL_PROFILES=y\n",
            ):
                config.write_text(invalid)
                try:
                    whitelist.run("check", variant, config)
                except ValueError:
                    pass
                else:
                    raise AssertionError(f"{variant} accepted invalid device configuration")
            config.write_text(result)
            whitelist.run("apply", variant, config)
            assert config.read_text() == result

print("All QCA whitelist variants and regression checks passed.")
