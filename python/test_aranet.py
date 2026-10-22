"""Tests for the Aranet4 protocol parsers, using real captured payloads."""

import struct

import pytest

from aranet import parse_advertisement, parse_reading

# Captured from a real device (fw v2.0.7, sw v1.5.45).
CURRENT_CHAR = bytes.fromhex("b30285010f272650012c019300")
ADV_PAYLOAD = bytes.fromhex("2107000200120f01b30285010f272650012c018100f1")


def test_parse_current_characteristic():
    r = parse_reading(CURRENT_CHAR)
    assert r.co2_ppm == 691
    assert r.temperature_c == pytest.approx(19.45)
    assert r.pressure_hpa == pytest.approx(999.9)
    assert r.humidity_pct == 38
    assert r.battery_pct == 80
    assert r.status == "green"
    assert r.interval_s == 300
    assert r.age_s == 147


def test_parse_advertisement_matches_characteristic():
    r = parse_advertisement({0x0702: ADV_PAYLOAD})
    assert r is not None
    assert r.co2_ppm == 691
    assert r.temperature_c == pytest.approx(19.45)
    assert r.pressure_hpa == pytest.approx(999.9)
    assert r.humidity_pct == 38
    assert r.battery_pct == 80
    assert r.status == "green"
    assert r.interval_s == 300
    assert r.age_s == 129


@pytest.mark.parametrize(
    "status_byte,name", [(0, "error"), (1, "green"), (2, "yellow"), (3, "red")]
)
def test_status_values(status_byte, name):
    data = bytearray(CURRENT_CHAR)
    data[8] = status_byte
    assert parse_reading(data).status == name


def test_unknown_status_is_reported_not_raised():
    data = bytearray(CURRENT_CHAR)
    data[8] = 99
    assert parse_reading(data).status == "unknown(99)"


def test_short_payload_rejected():
    with pytest.raises(ValueError, match="13 bytes"):
        parse_reading(CURRENT_CHAR[:9])


def test_advertisement_without_aranet_manufacturer_id():
    assert parse_advertisement({0x004C: ADV_PAYLOAD}) is None


def test_advertisement_too_short():
    assert parse_advertisement({0x0702: ADV_PAYLOAD[:10]}) is None


def test_staleness():
    fresh = parse_reading(CURRENT_CHAR)
    assert not fresh.is_stale  # age 147 < interval 300

    data = bytearray(CURRENT_CHAR)
    struct.pack_into("<H", data, 11, 400)  # age 400s > 300s interval
    assert parse_reading(data).is_stale


def test_fahrenheit_conversion():
    r = parse_reading(CURRENT_CHAR)
    assert r.temperature_c == pytest.approx(19.45)
    assert r.temperature_f == pytest.approx(67.01)  # 19.45C == 67.01F
