#!/usr/bin/env node
// Synthetic local route checks. No app, browser, audio, credentials or deployment.
// node gateway/Tests/share-player/nginx-denial.mjs --repo=/path/to/config/checkout
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {mkdtempSync, mkdirSync, writeFileSync, readFileSync, chmodSync} from 'node:fs';
import {join, resolve, dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
const args = process.argv.slice(2);
assert.ok(args.length <= 1 && args.every(x => x.startsWith('--repo=')), 'Only --repo is supported');
const repo = resolve(args[0]?.slice(7) ?? join(dirname(fileURLToPath(import.meta.url)), '../../..'));
const work = mkdtempSync('/private/tmp/baton-nginx-denial-');
chmodSync(work, 0o755);
const image = 'nginx:alpine', name = `baton-nginx-denial-${process.pid}`;
let container = null, networkCreated = false;
const requests = [];
const upstream = createServer((req, res) => {
  requests.push({method:req.method,path:req.url});
  res.setHeader('Content-Type','application/json');
  // Upstream errors for the cache-policy checks: one that states its own policy, as every
  // baton-share error does, and one that states none.
  if (req.url === '/v1/share/synthetic-error-with-policy') { res.statusCode = 410; res.setHeader('Cache-Control','no-store'); }
  if (req.url === '/v1/share/synthetic-error-bare') res.statusCode = 500;
  // A card's success policy, handed to nginx for a blob that is not on disk.
  if (req.url === '/v1/share/synthetic-accel-missing') {
    res.setHeader('Cache-Control','public, max-age=300');
    res.setHeader('X-Accel-Redirect','/_share_blobs/nginx-denial-fixture/card');
  }
  res.end(JSON.stringify({synthetic:true}));
});
const docker = args => execFileSync('docker', args, {encoding:'utf8', timeout:20000, stdio:['ignore','pipe','pipe']}).trim();
const serverListen = server => new Promise((resolve,reject) => {
  server.once('error',reject); server.listen(0,'127.0.0.1',() => resolve(server.address().port));
});
let result = {passed:false,syntheticOnly:true,configRepo:repo,checks:[]};
try {
  result.imageID = JSON.parse(docker(['image','inspect',image]))[0].Id; // never pull an image
  const upstreamPort = await serverListen(upstream);
  const reservation = createServer();
  const publicPort = await serverListen(reservation);
  await new Promise(resolve => reservation.close(resolve));
  for (const p of ['site','blobs','blobs/nginx-denial-fixture']) { mkdirSync(join(work,p),{recursive:true}); chmodSync(join(work,p),0o755); }
  writeFileSync(join(work,'site/404.html'),'Synthetic denial page\n',{mode:0o644});
  writeFileSync(join(work,'site/index.html'),'Synthetic route check\n',{mode:0o644});
  writeFileSync(join(work,'blobs/nginx-denial-fixture/audio'),'synthetic blob exists; direct access must fail\n',{mode:0o644});
  // A readable DMG, the control for the error cache-policy checks (TBX-1000000064). An
  // unreadable one (the 0.20.5 release's 403) is not reproducible here: Docker Desktop's
  // file sharing lets nginx read a 0600 file, so the 403 below comes from `return 403`.
  writeFileSync(join(work,'site/Baton-0.0.1.dmg'),'synthetic dmg\n',{mode:0o644});
  let site = readFileSync(join(repo,'deploy/nginx/default.conf'),'utf8');
  result.configSHA256 = createHash('sha256').update(site).digest('hex');
  const swap = (from,to) => { assert.equal(site.split(from).length,2,`Expected one config anchor ${from}`); site = site.replace(from,to); };
  swap('root  /usr/share/nginx/html;','root  /fixture/site;');
  // Variable upstream/resolver/location semantics remain the shipping configuration.
  swap('"http://baton-share:8790"',`"http://host.docker.internal:${upstreamPort}"`);
  swap('alias /srv/baton-share/blobs/;','alias /fixture/blobs/;');
  site = site.replaceAll('/etc/nginx/conf.d/share-proxy.inc','/fixture/share-proxy.inc');
  // Fixture-only locations that fail with a fixed status on a DMG path. Like every shipping
  // location, they declare no add_header, so the server-level Cache-Control applies.
  swap('location = /404.html { internal; }',`location = /404.html { internal; }
    location = /Baton-forbidden.dmg { return 403; }
    location = /Baton-error.dmg { return 500; }`);
  assert.ok(site.includes('internal;') && site.includes('/v1/share/admin/enforcement/'), 'Use the enforcement branch config');
  writeFileSync(join(work,'site.conf'),site,{mode:0o644});
  writeFileSync(join(work,'share-proxy.inc'),readFileSync(join(repo,'deploy/nginx/share-proxy.inc')),{mode:0o644});
  writeFileSync(join(work,'nginx.conf'),`daemon off; pid /tmp/nginx.pid; error_log stderr warn;
events { worker_connections 64; }
http { include /etc/nginx/mime.types; access_log off; client_body_temp_path /tmp/nginx-client; proxy_temp_path /tmp/nginx-proxy; include /fixture/site.conf; }
`,{mode:0o644});
  const mount = ['-v',`${work}:/fixture:ro`];
  result.syntax = docker(['run','--rm','--pull=never','--network','none',...mount,image,'nginx','-t','-c','/fixture/nginx.conf']);
  result.syntaxPassed = true;
  docker(['network','create',name]); networkCreated = true;
  container = docker(['run','--network',name,'-d','--rm','--pull=never','--name',name,'-p',`127.0.0.1:${publicPort}:80`,...mount,image,'nginx','-c','/fixture/nginx.conf']);
  assert.match(container,/^[a-f0-9]{64}$/);
  const bindings = JSON.parse(docker(['inspect',container]))[0].NetworkSettings.Ports['80/tcp'];
  assert.deepEqual(bindings,[{HostIp:'127.0.0.1',HostPort:String(publicPort)}],'only the owned literal loopback port is published');
  result.loopbackOnly = true;
  const base = `http://127.0.0.1:${publicPort}`;
  for (let i=0;;i++) {
    try { const response = await fetch(base+'/',{signal:AbortSignal.timeout(5000)}); assert.equal(response.status,200); break; }
    catch (error) { if(i>=40) throw error; await new Promise(resolve => setTimeout(resolve,200)); }
  }
  // Positive controls prove nginx can resolve/reach this particular local upstream.
  for (const path of ['/v1/share/config','/s/synthetic-control']) {
    const response = await fetch(base+path,{signal:AbortSignal.timeout(5000)}); assert.equal(response.status,200);
    assert.deepEqual(await response.json(),{synthetic:true});
  }
  assert.equal(requests.length,2,'positive controls reached the synthetic upstream');
  const protectedPaths = [
    '/v1/share/admin/enforcement/plan', '/v1/share/admin/enforcement/apply',
    '/v1/share/admin/enforcement/operations',
    '/v1/share/admin/enforcement/operations/00000000-0000-0000-0000-000000000001',
    '/v1/share/admin/enforcement/plan?extension=.css', '/v1/share/admin/enforcement/plan/',
    '/v1/share/%61dmin/enforcement/plan', '/v1/share/admin//enforcement/plan',
    '/v1/share/admin/enforcement', '/v1/share/admin/enforcement-adjacent',
    '/v1/share/admin/report', '/_share_blobs/nginx-denial-fixture/audio',
    '/_share_blobs/nginx-denial-fixture/audio?x=1', '/_share_%62lobs/nginx-denial-fixture/audio',
    '/_share_blobs/', '/_share_blobs'
  ];
  for (const path of protectedPaths) for (const method of ['GET','HEAD','POST','OPTIONS']) {
    const response = await fetch(base+path,{signal:AbortSignal.timeout(5000),method,headers:{Range:'bytes=0-5',...(method==='POST'?{'Content-Type':'application/json'}:{})},...(method==='POST'?{body:'{}'}:{})});
    await response.arrayBuffer();
    assert.equal(response.status,404,`${method} ${path}`);
    assert.equal(response.headers.get('cache-control'),'no-store, no-transform',`${method} ${path} uncacheable`);
    assert.equal(requests.length,2,`${method} ${path} must never proxy`);
    result.checks.push({method,path,status:response.status,proxied:false});
  }
  // Errors are never cacheable (web-cache-policy.md), whatever the URI's own policy. A DMG
  // path's own policy is a 30-day immutable one, and before TBX-1000000064 only a 404 was
  // exempt from it, so a 403 or 500 on a DMG path carried it to Cloudflare.
  result.cachePolicy = [];
  const cacheCase = async (path, status, policy, method = 'GET', headers = {}) => {
    const response = await fetch(base+path,{signal:AbortSignal.timeout(5000),method,headers});
    await response.arrayBuffer();
    assert.equal(response.status,status,`${method} ${path} status`);
    // Headers.get joins repeated headers with ", ", so a second Cache-Control fails here too.
    const actual = response.headers.get('cache-control');
    if (policy instanceof RegExp) assert.match(actual ?? '',policy,`${method} ${path} Cache-Control`);
    else assert.equal(actual,policy,`${method} ${path} Cache-Control`);
    result.cachePolicy.push({method,path,status,cacheControl:actual});
  };
  const noStore = /(^|, )no-store(, |$)/;
  await cacheCase('/Baton-0.0.1.dmg',200,'public, max-age=2592000, immutable');
  for (const method of ['GET','HEAD']) {
    await cacheCase('/Baton-forbidden.dmg',403,'no-store, no-transform',method);
    await cacheCase('/Baton-error.dmg',500,'no-store, no-transform',method);
    await cacheCase('/Baton-9.9.9.dmg',404,'no-store, no-transform',method);
  }
  // A proxied error that states its own policy keeps it, alone; one that states none gets no-store.
  await cacheCase('/v1/share/synthetic-error-with-policy',410,'no-store');
  await cacheCase('/v1/share/synthetic-error-bare',500,'no-store, no-transform');
  // A blob that fails after X-Accel-Redirect still carries the service's success policy,
  // so nginx must add no-store beside it. Likewise a Range the DMG cannot satisfy, whose
  // 416 nginx decides after the URI's immutable value was first computed. Both responses
  // also carry the inherited value, so these assert that no-store is present.
  await cacheCase('/v1/share/synthetic-accel-missing',404,noStore);
  await cacheCase('/Baton-0.0.1.dmg',416,noStore,'GET',{Range:'bytes=99999-'});
  assert.equal(requests.length,5,'exactly the three upstream error controls were forwarded');
  result.upstreamControlRequests = requests.length;
  result.passed = true;
  console.log(`PASS nginx syntax; ${result.checks.length} denied route/method checks404; ${result.cachePolicy.length} error cache-policy checks; exactly2 positive and3 error controls forwarded`);
} catch (error) {
  result.error = error instanceof Error ? error.message : 'Unknown local route check failure';
  console.error(result.error); process.exitCode=1;
} finally {
  if (container) {
    try { docker(['stop','-t','2',container]); result.ownedContainerStopped=true; }
    catch { result.ownedContainerStopped=false; process.exitCode=1; }
  }
  if (networkCreated) {
    try { docker(['network','rm',name]); result.ownedNetworkRemoved=true; }
    catch { result.ownedNetworkRemoved=false; process.exitCode=1; }
  }
  upstream.closeAllConnections();
  await new Promise(resolve => upstream.close(resolve));
  writeFileSync(join(work,'result.json'),JSON.stringify(result,null,2),{mode:0o600});
  console.log(`Evidence: ${work}/result.json`);
}
