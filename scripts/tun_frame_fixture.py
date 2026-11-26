"""Darwin utun frame fixtures for the packaged embedded-core smoke test."""
import socket
import struct
import time


def checksum(data):
    if len(data) % 2:
        data += b'\0'
    total = sum(struct.unpack('!' + 'H' * (len(data) // 2), data))
    while total >> 16:
        total = (total & 0xffff) + (total >> 16)
    return ~total & 0xffff


class TunnelFlow:
    def __init__(self, wire, family, protocol, source_port, target_port):
        self.wire = wire
        self.family = family
        self.protocol = protocol
        self.source_port = source_port
        self.target_port = target_port
        self.ipv6 = family == socket.AF_INET6
        self.source = socket.inet_pton(family, 'fd00:dead::2' if self.ipv6 else '10.9.0.2')
        self.target = socket.inet_pton(family, '2001:db8::1' if self.ipv6 else '192.0.2.10')

    def send(self, payload, sequence=0, acknowledgment=0, flags=0):
        if self.protocol == socket.IPPROTO_TCP:
            segment = struct.pack('!HHIIBBHHH', self.source_port, self.target_port, sequence, acknowledgment,
                                  5 << 4, flags, 65535, 0, 0) + payload
            checksum_offset = 16
        else:
            segment = struct.pack('!HHHH', self.source_port, self.target_port, 8 + len(payload), 0) + payload
            checksum_offset = 6
        length = len(segment)
        trailer = struct.pack('!I3xB', length, self.protocol) if self.ipv6 else struct.pack('!BBH', 0, self.protocol, length)
        crc = checksum(self.source + self.target + trailer + segment) or 0xffff
        segment = segment[:checksum_offset] + struct.pack('!H', crc) + segment[checksum_offset + 2:]
        if self.ipv6:
            header = struct.pack('!IHBB', 6 << 28, length, self.protocol, 64) + self.source + self.target
        else:
            header = struct.pack('!BBHHHBBH', 0x45, 0, 20 + length, 1, 0, 64, self.protocol, 0) + self.source + self.target
            header = header[:10] + struct.pack('!H', checksum(header)) + header[12:]
        self.wire.send(struct.pack('!I', self.family) + header + segment)

    def receive(self):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            self.wire.settimeout(max(.01, deadline - time.monotonic()))
            frame = self.wire.recv(65535)
            if frame[:4] != struct.pack('!I', self.family):
                continue
            ip = frame[4:]
            assert ip[0] >> 4 == (6 if self.ipv6 else 4)
            if ip[6 if self.ipv6 else 9] != self.protocol:
                continue
            segment = ip[40 if self.ipv6 else (ip[0] & 15) * 4:]
            if struct.unpack_from('!HH', segment) == (self.target_port, self.source_port):
                return segment
        raise TimeoutError('Embedded TUN did not return the expected flow')

    def tcp_exchange(self, request, expected_tail):
        sequence = 101
        self.send(b'', sequence=sequence, flags=0x02)
        syn_ack = self.receive()
        assert syn_ack[13] & 0x12 == 0x12
        ack = struct.unpack_from('!I', syn_ack, 4)[0] + 1
        sequence += 1
        self.send(b'', sequence, ack, 0x10)
        self.send(request, sequence, ack, 0x18)
        sequence += len(request)
        response = bytearray()
        while not response.endswith(expected_tail):
            segment = self.receive()
            payload = segment[(segment[12] >> 4) * 4:]
            if payload:
                assert struct.unpack_from('!I', segment, 4)[0] == ack
                response.extend(payload)
                ack = (ack + len(payload)) & 0xffffffff
                self.send(b'', sequence, ack, 0x10)
            if segment[13] & 0x05 and not response.endswith(expected_tail):
                raise AssertionError('Embedded TUN closed the TCP stream before the complete response')
        self.send(b'', sequence, ack, 0x14)
        return bytes(response)


def check_tun_frames(wire, udp, nonce, cycle):
    query = bytes.fromhex('656401000001000000000000') + b'\x03geo\x07invalid\0' + bytes.fromhex('00010001')
    answer_ip = socket.inet_aton('192.0.2.42')
    for index, family in enumerate([socket.AF_INET, socket.AF_INET6]):
        base = 23100 + 20 * cycle + 5 * index
        payload = nonce + bytes([cycle, index])
        datagram = TunnelFlow(wire, family, socket.IPPROTO_UDP, base, 34567)
        datagram.send(payload)
        data, sender = udp.recvfrom(65535)
        assert data == payload
        udp.sendto(b'reply' + data, sender)
        assert datagram.receive()[8:] == b'reply' + payload
        stream = TunnelFlow(wire, family, socket.IPPROTO_TCP, base + 1, 80)
        response = stream.tcp_exchange(b'GET / HTTP/1.0\r\nHost: localhost\r\n\r\n', nonce)
        assert response.split(b'\r\n\r\n', 1)[1] == nonce

        dns_udp = TunnelFlow(wire, family, socket.IPPROTO_UDP, base + 2, 53)
        dns_udp.send(query)
        answer = dns_udp.receive()[8:]
        assert answer[:2] == query[:2] and answer[-4:] == answer_ip
        dns_tcp = TunnelFlow(wire, family, socket.IPPROTO_TCP, base + 3, 53)
        answer = dns_tcp.tcp_exchange(struct.pack('!H', len(query)) + query, answer_ip)
        assert struct.unpack_from('!H', answer)[0] == len(answer) - 2 and answer[2:4] == query[:2]
