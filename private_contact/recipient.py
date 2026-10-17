"""Bounded DNS MX qualification, including explicit null-MX refusal."""
from __future__ import annotations
import ipaddress
import re
import secrets
import socket
import struct


def _name(packet: bytes, offset: int, depth: int = 0) -> tuple[str, int]:
    if depth > 8:
        raise ValueError()
    labels = []
    while True:
        size = packet[offset]
        offset += 1
        if size == 0:
            return '.'.join(labels) or '.', offset
        if size & 0xc0 == 0xc0:
            pointer = ((size & 0x3f) << 8) | packet[offset]
            rest, _ = _name(packet, pointer, depth + 1)
            return '.'.join(labels + ([] if rest == '.' else [rest])) or '.', offset + 1
        if size > 63:
            raise ValueError()
        labels.append(packet[offset:offset + size].decode('ascii').lower())
        offset += size


class RecipientPolicy:
    def __init__(self, resolver: str):
        self.resolver = str(ipaddress.ip_address(resolver))

    def _query(self, domain: str, kind: int) -> list[tuple[int, bytes, int]]:
        identifier = secrets.randbits(16)
        question = b''.join(bytes([len(label)]) + label.encode('ascii') for label in domain.split('.')) + b'\0'
        query = struct.pack('!6H', identifier, 0x0100, 1, 0, 0, 0) + question + struct.pack('!HH', kind, 1)
        family = socket.AF_INET6 if ':' in self.resolver else socket.AF_INET
        with socket.socket(family, socket.SOCK_DGRAM) as connection:
            connection.settimeout(3)
            connection.connect((self.resolver, 53))
            connection.send(query)
            packet = connection.recv(4096)
        actual, flags, questions, answers, _, _ = struct.unpack('!6H', packet[:12])
        if actual != identifier or flags & 0x0200 or not flags & 0x8000 or flags & 15 or questions != 1:
            raise ValueError()
        queried, offset = _name(packet, 12)
        query_kind, query_class = struct.unpack('!HH', packet[offset:offset + 4])
        if queried != domain or query_kind != kind or query_class != 1:
            raise ValueError()
        offset += 4
        result = []
        for _ in range(answers):
            _, offset = _name(packet, offset)
            record_kind, record_class, _, size = struct.unpack('!HHIH', packet[offset:offset + 10])
            offset += 10
            end = offset + size
            if end > len(packet):
                raise ValueError()
            if record_class == 1 and record_kind == kind:
                if kind == 15:
                    if size < 3:
                        raise ValueError()
                    _, name_end = _name(packet, offset + 2)
                    if name_end != end:
                        raise ValueError()
                elif kind in (1, 28) and size != (4 if kind == 1 else 16):
                    raise ValueError()
                result.append((kind, packet, offset))
            offset = end
        return result

    def __call__(self, address: str) -> bool:
        try:
            domain = address.rsplit('@', 1)[1].lower()
            if (len(domain) > 253 or not re.fullmatch(r'(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}', domain)
                    or domain.endswith('.invalid')):
                return False
            mx = self._query(domain, 15)
            names = [_name(packet, offset + 2)[0] for _, packet, offset in mx]
            if '.' in names:
                return False
            if names:
                return True
            # RFC5321 implicit MX applies only to domains without any MX record.
            return bool(self._query(domain, 1) or self._query(domain, 28))
        except Exception:
            return False
