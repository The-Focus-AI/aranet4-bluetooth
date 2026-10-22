"""Tests for the Aranet4 history-log parser, using real captured pages."""

import io
import struct
from datetime import datetime, timezone

import pytest

from aranet import (
    HISTORY_CO2,
    HISTORY_HUMIDITY,
    HISTORY_PRESSURE,
    HISTORY_TEMPERATURE,
    History,
    HistoryPageHeader,
    build_history_records,
    decode_history_value,
    format_history_summary,
    history_document,
    history_start_index,
    parse_history_header,
    parse_history_page,
    write_history_csv,
)

# First f0cd2005 page captured from the device (fw v2.0.7, sw v1.5.45):
# CO2, requested from index 1. Header says 117 values, then 549, 524, 552, ...
CO2_PAGE = bytes.fromhex(
    "042c01b013820001007525020c022802120228021e021f02180216021e0223022a022f0219022402110218022c021d02"
    "1a0231021b02160230021c022502300228023c0222022b022a022b023a02330229021c021d02180225022e022c022a02"
    "3d02270228024a0230022b0226023b022b022a023d0236022b022f022e022e022e0237024002310247023b023f024102"
    "2b0231022d0239024c022d024b023c023302460237023a022e0241023a024c023c023b02460250023c0244023d025402"
    "34024302430247023c0248023f0236023b024b023c0235023c0246023002380233023102500256023b02420232023902"
    "39024a02"
)

# First humidity page: 234 u8 values, all 55 % in this first page.
HUMIDITY_PAGE = bytes.fromhex(
    "022c01b01385000100ea3737373737373737373838383838383838383838383838383838383838383838383838383838"
    "383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838"
    "383838383838383838383838383838383838383838383838383838383838383838383838383838383838383737373737"
    "373636363635353535353534343434333333333333333333333333343434333434343434343433333333333333333333"
    "333232323332333333333332333333323232323232323232323030303030303030303131313131313131313131313131"
    "31313131"
)


def test_parse_co2_page_header():
    header = parse_history_header(CO2_PAGE)
    assert header == HistoryPageHeader(
        param=HISTORY_CO2,
        interval_s=300,
        total_readings=5040,
        age_s=130,
        start=1,
        count=117,
    )


def test_parse_co2_page_values():
    header, values = parse_history_page(CO2_PAGE)
    assert header.param == HISTORY_CO2
    assert len(values) == 117
    assert values[:4] == [549, 524, 552, 530]
    assert decode_history_value(HISTORY_CO2, values[0]) == 549


def test_parse_humidity_page_uses_single_byte_values():
    header, values = parse_history_page(HUMIDITY_PAGE)
    assert header.param == HISTORY_HUMIDITY
    assert header.count == 234
    assert len(values) == 234
    assert values[0] == 55
    assert max(values) == 56


def test_page_shorter_than_its_count_is_rejected():
    packet = struct.pack("<BHHHHB", HISTORY_CO2, 300, 10, 5, 1, 5) + b"\x00\x00"
    with pytest.raises(ValueError, match="only 1 fit"):
        parse_history_page(packet)


def test_unknown_parameter_is_rejected():
    packet = struct.pack("<BHHHHB", 9, 300, 10, 5, 1, 0)
    with pytest.raises(ValueError, match="unknown history parameter 9"):
        parse_history_page(packet)


def test_header_needs_ten_bytes():
    with pytest.raises(ValueError, match="at least 10 bytes"):
        parse_history_header(b"\x04\x2c\x01")


@pytest.mark.parametrize(
    "param,raw,expected",
    [
        (HISTORY_TEMPERATURE, 451, 22.55),
        (HISTORY_TEMPERATURE, 0x4000, None),
        (HISTORY_PRESSURE, 9997, 999.7),
        (HISTORY_PRESSURE, 0x8000, None),
        (HISTORY_CO2, 713, 713),
        (HISTORY_CO2, 0x8000, None),
        (HISTORY_HUMIDITY, 36, 36),
        (HISTORY_HUMIDITY, 100, 100),
        (HISTORY_HUMIDITY, 101, None),
    ],
)
def test_decode_history_value(param, raw, expected):
    assert decode_history_value(param, raw) == expected


def test_build_records_reconstructs_timestamps():
    series = {
        HISTORY_CO2: {1: 500, 2: 600, 3: 700},
        HISTORY_TEMPERATURE: {1: 20.0, 2: 21.0, 3: 22.0},
        HISTORY_HUMIDITY: {1: 40, 2: 41, 3: 42},
        HISTORY_PRESSURE: {1: 1000.0, 2: 1001.0, 3: 1002.0},
    }
    last = datetime(2026, 10, 22, 12, 0, tzinfo=timezone.utc)

    records = build_history_records(
        series, total=3, interval_s=300, start=1, last_measured_at=last
    )

    assert [r.timestamp for r in records] == [
        datetime(2026, 10, 22, 11, 50, tzinfo=timezone.utc),
        datetime(2026, 10, 22, 11, 55, tzinfo=timezone.utc),
        datetime(2026, 10, 22, 12, 0, tzinfo=timezone.utc),
    ]
    assert records[-1].co2_ppm == 700
    assert records[-1].temperature_c == 22.0
    assert records[-1].humidity_pct == 42
    assert records[-1].pressure_hpa == 1002.0


def test_build_records_skips_empty_slots():
    series = {HISTORY_CO2: {1: None, 2: 600}}
    last = datetime(2026, 10, 22, 12, 0, tzinfo=timezone.utc)

    records = build_history_records(
        series, total=2, interval_s=300, start=1, last_measured_at=last
    )

    assert len(records) == 1
    assert records[0].co2_ppm == 600
    assert records[0].timestamp == last


def test_history_start_index():
    assert history_start_index(5040, interval_s=300) == 1
    assert history_start_index(5040, last=288, interval_s=300) == 4753
    assert history_start_index(5040, days=1, interval_s=300) == 4753
    assert history_start_index(10, last=50, interval_s=300) == 1
    with pytest.raises(ValueError, match="logging interval"):
        history_start_index(10, days=1, interval_s=0)


def _sample_history() -> History:
    records = build_history_records(
        {
            HISTORY_CO2: {1: 500, 2: 600},
            HISTORY_TEMPERATURE: {1: 20.0, 2: 21.5},
            HISTORY_HUMIDITY: {1: 40, 2: 41},
            HISTORY_PRESSURE: {1: 1000.0, 2: 1001.5},
        },
        total=2,
        interval_s=300,
        start=1,
        last_measured_at=datetime(2026, 10, 22, 12, 0, tzinfo=timezone.utc),
    )
    return History(
        name="Aranet4 12345",
        serial="123456789012",
        firmware="v2.0.7",
        interval_s=300,
        total_records=2,
        start_index=1,
        fetched_at=datetime(2026, 10, 22, 12, 0, 10, tzinfo=timezone.utc),
        records=records,
    )


def test_csv_output():
    out = io.StringIO()
    write_history_csv(_sample_history(), out)
    lines = out.getvalue().splitlines()
    assert lines[0] == "timestamp,co2_ppm,temperature_c,humidity_pct,pressure_hpa,epoch_s"
    assert lines[1] == "2026-10-22T11:55:00+00:00,500,20.0,40,1000.0,1792670100"
    assert lines[2] == "2026-10-22T12:00:00+00:00,600,21.5,41,1001.5,1792670400"


def test_json_document():
    doc = history_document(_sample_history())
    assert doc["device"]["serial"] == "123456789012"
    assert doc["interval_s"] == 300
    assert doc["total_records"] == 2
    assert doc["records"][1] == {
        "timestamp": "2026-10-22T12:00:00+00:00",
        "co2_ppm": 600,
        "temperature_c": 21.5,
        "humidity_pct": 41,
        "pressure_hpa": 1001.5,
        "epoch_s": 1792670400,
    }


def test_summary_reports_count_and_ranges():
    text = format_history_summary(_sample_history(), "out.csv")
    assert "2 records at 300 s" in text
    assert "CO2 500–600 ppm (avg 550)" in text
    assert "20.00–21.50 °C" in text
    assert "Wrote 2 records to out.csv" in text

    single = _sample_history()
    single.records = single.records[-1:]
    text = format_history_summary(single, "one.csv")
    assert "1 record at 300 s" in text
    assert "CO2 600 ppm" in text
    assert "Wrote 1 record to one.csv" in text
