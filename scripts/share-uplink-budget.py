#!/usr/bin/env python3
"""Offline budget calculator: performs no network requests or load testing."""
import argparse
import json
import math


def budget(listeners: int, duration: int, bitrate: int, seconds: int, reserve: int) -> dict:
    if listeners < 1 or duration < 1 or bitrate < 1 or seconds < 1 or not 0 <= reserve < 100:
        raise ValueError("positive inputs and reserve from 0 to 99 required")
    plaintext = math.ceil(duration * bitrate / 8)
    # BSH1 at its standard 65536-byte record size: 20-byte header + 16 per record.
    sealed = plaintext + 20 + 16 * math.ceil(plaintext / 65536)
    return {"listeners": listeners, "estimatedSealedBytesPerSong": sealed,
            "burstBytes": listeners * sealed, "deliveryWindowSeconds": seconds,
            "payloadBurstMbps": listeners * sealed * 8 / seconds / 1_000_000,
            "capacityMbpsWithReserve": listeners * sealed * 8 / seconds / 1_000_000 / (1 - reserve / 100),
            "reservePercent": reserve, "sustainedPlaybackMbps": listeners * bitrate / 1_000_000,
            "measurement": False}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--listeners", type=int, default=50)
    parser.add_argument("--duration-seconds", type=int, default=180)
    parser.add_argument("--bitrate-bps", type=int, default=320_000)
    parser.add_argument("--delivery-seconds", type=int, default=10)
    parser.add_argument("--reserve-percent", type=int, default=25)
    args = parser.parse_args()
    try:
        result = budget(args.listeners, args.duration_seconds, args.bitrate_bps,
                        args.delivery_seconds, args.reserve_percent)
    except ValueError as error:
        parser.error(str(error))
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
