#!/usr/bin/env node
// Private local-only seeding; does not start a browser or print invitations.
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { seal } from '../gateway/Sources/BatonShareServer/Web/share-crypto.mjs';
const [configPath] = process.argv.slice(2);
const budget = Number(process.env.INCOMING_FIXTURE_REMAINING_MS ?? 120_000);
assert.ok(Number.isFinite(budget) && budget > 0 && budget <= 810_000);
const deadline = performance.now() + budget;
const remaining = () => { const value=deadline-performance.now(); assert.ok(value>0,'local seed deadline exceeded'); return value; };
const config = JSON.parse(readFileSync(configPath));
const base = new URL(config.shareBase);
assert.equal(base.protocol, 'http:'); assert.equal(base.hostname, '127.0.0.1');
assert.ok(base.port && base.pathname === '/' && !base.username && !base.password && !base.search && !base.hash);
const secret = Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString('base64url');
const song = new Uint8Array(readFileSync(config.song));
assert.ok(song.length < 300_000);
async function api(method, path, body, json = false) {
  assert.ok(path.startsWith('/') && !path.startsWith('//'));
  const response = await fetch(base.origin + path, { method, redirect:'error', signal:AbortSignal.timeout(Math.max(1,Math.floor(Math.min(15_000,remaining())))),
    headers:{Authorization:`Bearer ${secret}`, ...(json ? {'Content-Type':'application/json'} : {})}, body });
  assert.ok(response.ok, `local fixture request failed (${response.status})`);
  const text = await response.text(); return text ? JSON.parse(text) : null;
}
const shares = [];
for (const label of ['A','B']) {
  remaining();
  const key = crypto.getRandomValues(new Uint8Array(16));
  const audio = await seal(song, key, 'audio');
  const metadata = {title:`Incoming Fixture ${label}`,artist:'Synthetic Receiver Probe',album:'Isolated Fixtures',
    durationSeconds:40,from:'Local Fixture',note:`Private note ${label}`,peaks:[]};
  if (label==='A' && config.recordingID) metadata.recordingID=config.recordingID;
  const encryptedMeta = await seal(new TextEncoder().encode(JSON.stringify(metadata)), key, 'meta');
  const created = await api('POST','/v1/share/shares',JSON.stringify({expiresInSeconds:86400,playCap:100,
    encryptedMeta:Buffer.from(encryptedMeta).toString('base64'),durationBucket:'<1m',audioBytes:audio.length,
    audioSHA256:Buffer.from(await crypto.subtle.digest('SHA-256',audio)).toString('hex'),
    client:{platform:'macos',appVersion:'incoming-local-fixture'}}),true);
  await api('PUT',created.uploads.audio,audio);
  await api('POST',`/v1/share/shares/${created.id}/finalize`);
  shares.push({id:created.id,title:metadata.title,url:`baton://share/${created.id}#${Buffer.from(key).toString('base64url')}`});
}
writeFileSync(config.output,JSON.stringify({shares},null,2),{mode:0o600,flag:'wx'});
