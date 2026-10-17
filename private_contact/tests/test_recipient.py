"""Recipient admission observed at the captured UDP DNS transport boundary."""
import socket
import struct
import unittest
from unittest.mock import patch

from private_contact.recipient import RecipientPolicy


class CapturedDNS:
    def __init__(self, outcome):
        self.outcome, self.sent, self.destination = outcome, None, None

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def settimeout(self, timeout):
        self.timeout = timeout

    def connect(self, destination):
        self.destination = destination

    def send(self, wire):
        self.sent = wire

    def recv(self, limit):
        if self.outcome == 'timeout':
            raise socket.timeout()
        # Captured response shape: same question, compressed owner, one MX RR.
        answer = (b'\x00\x00\x00' if self.outcome == 'null' else
                  b'\x00\x0a\x04mail\x07example\x04test\x00')
        return (self.sent[:2] + struct.pack('!5H', 0x8180, 1, 1, 0, 0)
                + self.sent[12:] + b'\xc0\x0c'
                + struct.pack('!HHIH', 15, 1, 300, len(answer)) + answer)


class RecipientBoundaryTests(unittest.TestCase):
    def test_mx_name_cannot_read_past_its_record_data(self):
        class ShortMX(CapturedDNS):
            declared_size = 2
            def recv(self, limit):
                # Only preference belongs to the RR. The plausible hostname
                # after it must not qualify this malformed MX response.
                return (self.sent[:2] + struct.pack('!5H', 0x8180, 1, 1, 0, 0)
                        + self.sent[12:] + b'\xc0\x0c'
                        + struct.pack('!HHIH', 15, 1, 300, self.declared_size)
                        + b'\x00\x0a\x04mail\x07example\x04test\x00')
        for declared_size in (2, 20, 22):
            with self.subTest(declared_size=declared_size):
                transport = ShortMX('mx')
                transport.declared_size = declared_size
                with patch('private_contact.recipient.socket.socket', return_value=transport):
                    self.assertFalse(RecipientPolicy('192.0.2.53')('fixture@example.test'))

    def test_implicit_mx_requires_a_complete_address_record(self):
        class ShortAddress(CapturedDNS):
            def recv(self, limit):
                kind = struct.unpack('!HH', self.sent[-4:])[0]
                if kind == 15:
                    return (self.sent[:2] + struct.pack('!5H', 0x8180, 1, 0, 0, 0)
                            + self.sent[12:])
                return (self.sent[:2] + struct.pack('!5H', 0x8180, 1, 1, 0, 0)
                        + self.sent[12:] + b'\xc0\x0c'
                        + struct.pack('!HHIH', kind, 1, 300, 3) + b'\xc0\x00\x02')
        with patch('private_contact.recipient.socket.socket', return_value=ShortAddress('mx')):
            self.assertFalse(RecipientPolicy('192.0.2.53')('fixture@example.test'))

    def test_valid_compressed_mx_name_remains_admitted(self):
        class CompressedMX(CapturedDNS):
            def recv(self, limit):
                return (self.sent[:2] + struct.pack('!5H', 0x8180, 1, 1, 0, 0)
                        + self.sent[12:] + b'\xc0\x0c'
                        + struct.pack('!HHIH', 15, 1, 300, 4) + b'\x00\x0a\xc0\x0c')
        with patch('private_contact.recipient.socket.socket', return_value=CompressedMX('mx')):
            self.assertTrue(RecipientPolicy('192.0.2.53')('fixture@example.test'))

    def test_valid_implicit_ipv4_and_ipv6_mx_remain_admitted(self):
        class Address(CapturedDNS):
            def recv(self, limit):
                kind = struct.unpack('!HH', self.sent[-4:])[0]
                if kind != self.address_kind:
                    return (self.sent[:2] + struct.pack('!5H', 0x8180, 1, 0, 0, 0)
                            + self.sent[12:])
                address = b'\xc0\x00\x02\x01' if kind == 1 else bytes.fromhex('20010db8000000000000000000000001')
                return (self.sent[:2] + struct.pack('!5H', 0x8180, 1, 1, 0, 0)
                        + self.sent[12:] + b'\xc0\x0c'
                        + struct.pack('!HHIH', kind, 1, 300, len(address)) + address)
        for kind in (1, 28):
            with self.subTest(kind=kind):
                transport = Address('mx')
                transport.address_kind = kind
                with patch('private_contact.recipient.socket.socket', return_value=transport):
                    self.assertTrue(RecipientPolicy('192.0.2.53')('fixture@example.test'))

    def test_captured_mx_null_mx_timeout_and_reserved_domain_admission(self):
        for outcome, expected in (('mx', True), ('null', False), ('timeout', False)):
            with self.subTest(outcome=outcome):
                transport = CapturedDNS(outcome)
                with patch('private_contact.recipient.socket.socket', return_value=transport):
                    self.assertEqual(RecipientPolicy('192.0.2.53')('fixture@example.test'), expected)
                self.assertEqual(transport.destination, ('192.0.2.53', 53))
                self.assertEqual(transport.timeout, 3)
        with patch('private_contact.recipient.socket.socket') as unused:
            self.assertFalse(RecipientPolicy('192.0.2.53')('fixture@example.invalid'))
            unused.assert_not_called()
