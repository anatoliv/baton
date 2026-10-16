#!/usr/bin/env python3
"""Verify committed capacity arithmetic offline; optionally verify retained receipt hashes."""
import argparse
import base64
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def check(condition, message):
    if not condition:
        raise ValueError(message)


def close(actual, expected):
    return abs(Fraction(str(actual)) - expected) <= Fraction(1, 1_000_000)


def sealed_length(plain, record_size=65_536):
    # Derive from BSH1 framing; vectors include a different record size and empty input.
    records = max(1, (plain + record_size - 1) // record_size)
    return plain + 20 + 16 * records


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--verify-retained', action='store_true',
                        help='also require exact local receipt files and their SHA-256 hashes')
    args = parser.parse_args()
    data = json.loads((ROOT / 'evidence/song-sharing-capacity-2026-10-04.json').read_text())
    groups = 0
    scope, baseline = data['scope'], data['baseline']
    check(scope['measurementOfOriginCapacity'] is False and scope['newNetworkRequestsExecuted'] is False
          and scope['capacityCertifiedListeners'] is None and baseline['capacityMeasurement'] is False
          and baseline['providerContractedUplinkVerified'] is False, 'unknown capacity provenance changed')
    rate = Fraction(baseline['txBytes'] * 8, 1_000_000) / Fraction(str(baseline['sampleDurationSeconds']))
    check(close(baseline['observedOrdinaryTxMbps'], rate), 'ordinary traffic rate mismatch')
    groups += 1

    vectors = json.loads((ROOT / 'specs/share-crypto/vectors.json').read_text())['positive']
    for vector in vectors:
        plain = len(base64.b64decode(vector['plaintext']))
        actual = len(base64.b64decode(vector['ciphertext']))
        check(sealed_length(plain, vector['recordSize']) == actual, 'format-vector length mismatch')
    mp3 = data['syntheticMP3']
    check(sealed_length(mp3['plainBytes']) == mp3['sealedBytes'] and mp3['networkExecuted'] is False,
          'synthetic MP3 size/provenance mismatch')
    groups += 1

    observed = data['startupObservations']
    check(len(observed) == 2 and {item['profile'] for item in observed} == {'local', 'shaped'},
          'missing startup profile')
    for item in observed:
        payload, timing = item['payload'], item['timingMs']
        check(item['passed'] is True and item['exitCode'] == 0 and item['fixtureExitCode'] == 0
              and item['cleanupVerified'] is True and item['syntheticOnly'] is True, 'unqualified startup receipt')
        check(sealed_length(payload['plainBytes']) == payload['sealedBytes'], 'startup ciphertext length mismatch')
        check(0 <= timing['download'] <= timing['decryptFinished'] <= timing['firstAdvancingClock'],
              'startup timing order mismatch')
        if payload['downloadMbps']:
            ideal_ms = Fraction(payload['sealedBytes'] * 8, payload['downloadMbps'] * 1000)
            check(Fraction(str(timing['download'])) >= ideal_ms, 'shaped transfer below body-time lower bound')
    check(observed[0]['payload']['sealedBytes'] == observed[1]['payload']['sealedBytes'], 'different startup songs')
    groups += 1

    source = (ROOT / 'Packages/BatonShareKit/Sources/BatonShareKit/ShareLimits.swift').read_text()
    maximum = int(re.search(r'maxAudioBytes = ([\d_]+)', source)[1].replace('_', ''))
    sizes = {'syntheticMP3': mp3['sealedBytes'], 'syntheticWAV': observed[0]['payload']['sealedBytes'],
             '180s320kbps': sealed_length(180 * 320_000 // 8), 'maximumAdmittedAudio': maximum}
    check(len(data['burstCases']) == 12, 'budget scenario count changed')
    seen = set()
    for case in data['burstCases']:
        identity = (case['case'], case['listeners'])
        check(identity not in seen, 'duplicate budget scenario')
        seen.add(identity)
        size, listeners = sizes[case['case']], case['listeners']
        check(listeners in (5, 20, 50) and case['sealedBytesPerSong'] == size
              and case['deliveryWindowSeconds'] == 10 and case['reservePercent'] == 25, 'scenario inputs mismatch')
        burst = size * listeners
        mbps = Fraction(burst * 8, 10 * 1_000_000)
        check(case['burstBytes'] == burst and close(case['payloadMbps'], mbps)
              and close(case['requiredMbpsWithReserve'], mbps / Fraction(3, 4))
              and close(case['transferSecondsAtHypothetical100MbpsWithReserve'], Fraction(burst * 8, 75_000_000)),
              'burst/rate/transfer arithmetic mismatch')
    groups += 1

    monthly = data['monthlyIllustration']
    downloads = monthly['createdShares'] * monthly['fullAudioDownloadsPerShare']
    check(monthly['forecast'] is False and monthly['fullAudioDownloads'] == downloads
          and close(monthly['syntheticWAVBodyGB'], Fraction(sizes['syntheticWAV'] * downloads, 1_000_000_000))
          and close(monthly['maximumAudioBodyGB'], Fraction(maximum * downloads, 1_000_000_000)),
          'monthly illustration arithmetic/provenance mismatch')
    groups += 1

    probe = data['preparedProbe']
    requests = sum(probe['stagesListeners']) * probe['roundsPerStage']
    check(probe['executed'] is False and probe['automaticRetries'] == 0 and probe['followRedirects'] is False,
          'probe has not been executed/expanded')
    check(requests == probe['requestsTotal'] == 8 and max(probe['stagesListeners']) == probe['maxSimultaneousRequests'] == 5,
          'probe request/admission bound mismatch')
    check(probe['audioBytesPerRequest'] == mp3['sealedBytes'] <= probe['maxBodyBytesPerRequest'] == 1_048_576
          and probe['expectedAudioBodyBytes'] == requests * mp3['sealedBytes']
          and probe['maxAudioBodyBytes'] == requests * probe['maxBodyBytesPerRequest'], 'probe byte budget mismatch')
    check(close(probe['aggregateMaxMbpsAtFiveRequests'], Fraction(5 * probe['maxPerRequestBytesPerSecond'] * 8, 1_000_000))
          and probe['perRequestDeadlineSeconds'] * len(probe['stagesListeners']) <= probe['overallDeadlineSeconds'] == 60,
          'probe rate/time bound mismatch')
    groups += 1

    refs = [baseline['receipt'], mp3['receipt']]
    for item in observed:
        refs.extend([item['receipt'], item['statusReceipt']])
    if args.verify_retained:
        for ref in refs:
            check(hashlib.sha256(Path(ref['path']).read_bytes()).hexdigest() == ref['sha256'],
                  'retained receipt hash mismatch: ' + ref['path'])
        original = json.loads(Path(baseline['receipt']['path']).read_text())
        check(original['sampleDurationSeconds'] == baseline['sampleDurationSeconds']
              and original['ordinaryTrafficByteDeltas'] == {'tx_bytes': baseline['txBytes'], 'rx_bytes': baseline['rxBytes']}
              and original['capacityMeasurement'] is False
              and original['providerContractedUplinkVerified'] is False, 'baseline projection differs from receipt')
        original = json.loads(Path(mp3['receipt']['path']).read_text())
        check(original['MP3PlaintextBytes'] == mp3['plainBytes'] and original['sealedAudioBytes'] == mp3['sealedBytes']
              and original['coverBytes'] == mp3['coverBytes'] and original['networkExecuted'] is False,
              'MP3 projection differs from receipt')
        for item in observed:
            original = json.loads(Path(item['receipt']['path']).read_text())
            status = json.loads(Path(item['statusReceipt']['path']).read_text())
            check(all(original['profile'][key] == value for key, value in item['payload'].items())
                  and original['timingMs'] == item['timingMs'] and original['passed'] is True,
                  'startup projection differs from receipt')
            check(status['sourceCommit'] == item['harnessSource'] and status['binarySHA256'] == item['binarySHA256']
                  and status['exitCode'] == status['fixtureExitCode'] == 0 and status['syntheticOnly'] is True
                  and status['cleanup']['verified'] is True, 'startup status differs from receipt')
        groups += 1
    print(f'PASS: {groups} check groups; {len(vectors)} independent BSH1 vectors; 12 burst scenarios'
          + (f'; {len(refs)} retained receipt hashes' if args.verify_retained else '') + '; no network requests')


if __name__ == '__main__':
    main()
