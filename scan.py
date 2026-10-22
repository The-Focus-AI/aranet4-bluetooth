"""Scan for BLE devices and report anything that looks like an Aranet."""

import asyncio
import sys

from bleak import BleakScanner


async def main() -> None:
    timeout = float(sys.argv[1]) if len(sys.argv) > 1 else 10.0
    print(f"Scanning for {timeout:.0f}s ...", flush=True)

    seen = {}

    def on_detect(device, adv):
        seen[device.address] = (device, adv)

    scanner = BleakScanner(detection_callback=on_detect)
    await scanner.start()
    await asyncio.sleep(timeout)
    await scanner.stop()

    print(f"\n{len(seen)} device(s) seen\n")
    for address, (device, adv) in sorted(seen.items()):
        name = device.name or adv.local_name or "(no name)"
        hit = "  <-- ARANET" if "aranet" in name.lower() else ""
        print(f"{address}  rssi={adv.rssi:4d}  {name}{hit}")
        if adv.service_uuids:
            print(f"    services: {adv.service_uuids}")
        if adv.manufacturer_data:
            for cid, payload in adv.manufacturer_data.items():
                print(f"    mfr 0x{cid:04x}: {payload.hex()}")


if __name__ == "__main__":
    asyncio.run(main())
