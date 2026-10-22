"""Connect to an Aranet4 and dump its GATT tree + raw characteristic payloads."""

import asyncio
import sys

from bleak import BleakClient, BleakScanner


async def find_aranet(timeout: float = 20.0):
    print("Scanning for Aranet ...", flush=True)
    device = await BleakScanner.find_device_by_filter(
        lambda d, adv: "aranet" in ((d.name or "") + (adv.local_name or "")).lower(),
        timeout=timeout,
    )
    return device


async def main() -> None:
    address = sys.argv[1] if len(sys.argv) > 1 else None
    if address:
        device = await BleakScanner.find_device_by_address(address, timeout=20.0)
    else:
        device = await find_aranet()
    if device is None:
        print("No Aranet device found.")
        return

    print(f"Connecting to {device.name} [{device.address}] ...", flush=True)
    async with BleakClient(device, timeout=30.0) as client:
        print(f"Connected: {client.is_connected}\n")

        for service in client.services:
            print(f"SERVICE {service.uuid}  ({service.description})")
            for char in service.characteristics:
                props = ",".join(char.properties)
                print(f"  CHAR {char.uuid}  [{props}]")
                if "read" in char.properties:
                    try:
                        val = await client.read_gatt_char(char)
                        print(f"       value({len(val)}B) = {val.hex()}")
                    except Exception as exc:
                        print(f"       read failed: {exc}")
            print()


if __name__ == "__main__":
    asyncio.run(main())
