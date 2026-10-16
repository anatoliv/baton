// Offline wire/payload regression: fetch is mocked, no listeners/native processes.
import assert from 'node:assert/strict';
import {mkdtempSync,writeFileSync,readFileSync,rmSync,statSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {open} from '../gateway/Sources/BatonShareServer/Web/share-crypto.mjs';
const root=mkdtempSync(join(tmpdir(),'baton-incoming-seed-test-'));
const originals={argv:process.argv,fetch:globalThis.fetch};
const minted=[];
try {
 const payload=Buffer.from('synthetic fixture bytes');writeFileSync(join(root,'song'),payload);
 const output=join(root,'links.json'); const config=join(root,'config.json');
 writeFileSync(config,JSON.stringify({shareBase:'http://127.0.0.1:18765',song:join(root,'song'),output,recordingID:'83d9ea58-1a5b-4b02-8dc3-2955c705e326'}));
 globalThis.fetch=async (url,options)=>{
  assert.equal(new URL(url).origin,'http://127.0.0.1:18765');assert.equal(options.redirect,'error');
  if(options.method==='POST' && new URL(url).pathname==='/v1/share/shares') {
   const data=JSON.parse(options.body);assert.equal(data.preview,undefined);assert.equal(data.durationBucket,'<1m');
   assert.equal(data.client.platform,'macos'); assert.ok(data.audioBytes<300000);
   const id=['AAAAAAAAAAAAAAAAAAAAAA','BBBBBBBBBBBBBBBBBBBBBB'][minted.length];
   minted.push({id,data});return {ok:true,text:async()=>JSON.stringify({id,uploads:{audio:`/v1/share/shares/${id}/audio`}})};
  }
  const entry=minted.at(-1);
  if(options.method==='PUT'){entry.audio=options.body;return {ok:true,text:async()=>''};}
  assert.equal(new URL(url).pathname,`/v1/share/shares/${entry.id}/finalize`);
  return {ok:true,text:async()=>''};
 };
 process.argv=['node','seed',config];await import('./seed-incoming-share-fixture.mjs');
 const links=JSON.parse(readFileSync(output)).shares;assert.equal(links.length,2);
 for(let index=0;index<2;index++) {
  const url=new URL(links[index].url);assert.equal(url.protocol,'baton:');assert.equal(url.hostname,'share');
  const key=Buffer.from(url.hash.slice(1),'base64url');assert.equal(key.length,16);
  assert.deepEqual(Buffer.from(await open(minted[index].audio,key,'audio')),payload);
  const metadata=JSON.parse(new TextDecoder().decode(await open(Buffer.from(minted[index].data.encryptedMeta,'base64'),key,'meta')));
  assert.equal(metadata.title,links[index].title);assert.equal(metadata.durationSeconds,40);
  assert.equal(metadata.recordingID,index===0?'83d9ea58-1a5b-4b02-8dc3-2955c705e326':undefined);
 }
 assert.equal(statSync(output).mode&0o777,0o600);
 console.log('PASS: two bounded private synthetic shares, exact encrypted audio/metadata, local-only URLs, private invitation file; no network/native actions');
} finally {process.argv=originals.argv;globalThis.fetch=originals.fetch;rmSync(root,{recursive:true,force:true});}
