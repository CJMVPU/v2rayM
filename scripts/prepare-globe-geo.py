#!/usr/bin/env python3
"""Compile official DB-IP City Lite CSV into sorted, memory-mappable range tables.

Usage: prepare-globe-geo.py dbip-city-lite-YYYY-MM.csv.gz output-directory
Source: https://db-ip.com/db/download/ip-to-city-lite (CC BY 4.0).
No browsing destinations are sent to a geolocation API at runtime.
"""
import csv
import gzip
import ipaddress
import json
from pathlib import Path
import struct
import sys

source, output = Path(sys.argv[1]), Path(sys.argv[2])
output.mkdir(parents=True, exist_ok=True)
places, indices = [], {}
counts = {4: 0, 6: 0}
previous = {4: -1, 6: -1}
with gzip.open(source, 'rt', encoding='utf-8', newline='') as stream, \
        (output / 'ipv4.bin').open('wb') as v4, (output / 'ipv6.bin').open('wb') as v6:
    for row in csv.reader(stream):
        first, last = ipaddress.ip_address(row[0]), ipaddress.ip_address(row[1])
        assert first.version == last.version and int(first) <= int(last)
        assert int(first) > previous[first.version], 'Ranges must be sorted and disjoint'
        previous[first.version] = int(last)
        country, city, lat, lon = row[3], row[5], float(row[6]), float(row[7])
        assert -90 <= lat <= 90 and -180 <= lon <= 180
        key = (country, city, lat, lon)
        if key not in indices:
            indices[key] = len(places)
            places.append(dict(country=country, city=city, latitude=lat, longitude=lon))
        target = v4 if first.version == 4 else v6
        target.write(first.packed + last.packed + struct.pack('>I', indices[key]))
        counts[first.version] += 1
(output / 'places.json').write_text(json.dumps(places, ensure_ascii=False, separators=(',', ':')))
print(json.dumps(dict(ranges=counts, places=len(places), source=source.name)))
