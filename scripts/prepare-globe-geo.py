#!/usr/bin/env python3
"""Compile official DB-IP City Lite CSV into sorted, memory-mappable range tables.

Usage: prepare-globe-geo.py dbip-city-lite-YYYY-MM.csv.gz output-directory
Source: https://db-ip.com/db/download/ip-to-city-lite (CC BY 4.0).
No browsing destinations are sent to a geolocation API at runtime.
"""
import csv
import gzip
import ipaddress
import hashlib
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
# Header: magic, count, record width. Each 24-byte big-endian record stores
# UTF-8 payload offset, country/city lengths, latitude and longitude. Readers
# map the table and decode only the matching place, preserving exact doubles.
records, strings = bytearray(), bytearray()
for place in places:
    country, city = place['country'].encode('utf-8'), place['city'].encode('utf-8')
    assert len(country) <= 65535 and len(city) <= 65535
    records.extend(struct.pack('>IHHdd', len(strings), len(country), len(city), place['latitude'], place['longitude']))
    strings.extend(country + city)
(output / 'places.bin').write_bytes(b'V2MLOC01' + struct.pack('>II', len(places), 24) + records + strings)
def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
manifest = dict(formatVersion=1, input=dict(file=source.name,
    sourceURL='https://download.db-ip.com/free/' + source.name, sha256=digest(source)),
    outputs={name: dict(sha256=digest(output / name), bytes=(output / name).stat().st_size)
             for name in ['ipv4.bin', 'ipv6.bin', 'places.bin']})
(output / 'geodata-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps(dict(ranges=counts, places=len(places), source=source.name)))
