// No browser/media: a disposable Node process stands in for CDP's browser PID.
import {test} from "node:test";
import assert from "node:assert/strict";
import {spawn} from "node:child_process";
import {once} from "node:events";
import {mkdtempSync,mkdirSync,readFileSync,realpathSync,rmSync,symlinkSync,existsSync,writeFileSync} from "node:fs";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {registerOwnedBrowser,registerOwnedBrowserServer} from "./startup.mjs";

async function fixture(check) {
  const evidence=mkdtempSync(join(tmpdir(),"share-registry-test-"));
  const child=spawn(process.execPath,["-e","setInterval(()=>{},1000)"],{detached:true,stdio:"ignore"});
  await once(child,"spawn");
  const calls=[];let detached=false;
  const browser={newBrowserCDPSession:async()=>({send:async method=>{
    calls.push(method);
    if(method==="SystemInfo.getProcessInfo")return {processInfo:[{id:child.pid,type:"browser"}]};
    throw new Error("Browser.getBrowserCommandLine unavailable without --enable-automation");
  },detach:async()=>{detached=true;}})};
  try {await check({browser,evidence,child,calls,detached:()=>detached});}
  finally {
    process.kill(-child.pid,"SIGKILL");await once(child,"exit");rmSync(evidence,{recursive:true,force:true});
  }
}
const nonce="ab".repeat(16);

test("registry qualifies when command-line API is unsupported and never called",async()=>fixture(async({browser,evidence,child,calls,detached})=>{
  await registerOwnedBrowser(browser,evidence,nonce,process.execPath);
  const registry=JSON.parse(readFileSync(join(evidence,"startup-process-registry.json"),"utf8"));
  assert.equal(registry.browserGroup,child.pid);assert.equal(registry.uid,process.getuid());
  assert.equal(registry.canonicalExecutable,realpathSync(process.execPath));
  assert.ok(registry.entries[0].started);assert.deepEqual(calls,["SystemInfo.getProcessInfo"]);assert.equal(detached(),true);
}));

test("explicit full executable alias resolves to the exact owned process",async()=>fixture(async({browser,evidence})=>{
  const alias=join(evidence,"full-runtime-alias");symlinkSync(process.execPath,alias);
  await registerOwnedBrowser(browser,evidence,nonce,alias);
  const registry=JSON.parse(readFileSync(join(evidence,"startup-process-registry.json"),"utf8"));
  assert.equal(registry.requestedExecutable,alias);assert.equal(registry.canonicalExecutable,realpathSync(process.execPath));
}));

test("a different expected executable cannot self-qualify from ps metadata",async()=>fixture(async({browser,evidence,detached})=>{
  await assert.rejects(registerOwnedBrowser(browser,evidence,nonce,"/bin/echo"),/explicit cached runtime/);
  assert.equal(existsSync(join(evidence,"startup-process-registry.json")),false);assert.equal(detached(),true);
}));

test("measurement does not require the unsupported command-line query either",()=>{
  const source=readFileSync(new URL("./startup.mjs",import.meta.url),"utf8");
  assert.doesNotMatch(source,/\.send\(["']Browser\.getBrowserCommandLine["']/);
});


test("launchServer registry pins the public child and selected native executable before connect",async()=>fixture(async({evidence,child})=>{
  registerOwnedBrowserServer({process:()=>child},evidence,nonce,{launcher:process.execPath});
  const registry=JSON.parse(readFileSync(join(evidence,"startup-process-registry.json"),"utf8"));
  assert.equal(registry.browserGroup,child.pid);assert.match(registry.launcher.sha256,/^[a-f0-9]{64}$/);
  assert.equal(registry.nativeRuntime.path,realpathSync(process.execPath));
  assert.match(registry.ownershipSource,/before connect/);
}));

test("launchServer public spawnfile mismatch refuses browser identity",async()=>fixture(async({evidence,child})=>{
  assert.throws(()=>registerOwnedBrowserServer({process:()=>child},evidence,nonce,{launcher:"/bin/echo"}),/selected cached launcher/);
  assert.equal(existsSync(join(evidence,"startup-process-registry.json")),false);
}));

test("launchServer registry ignores an unrelated valid negative UID row",async()=>fixture(async({evidence,child})=>{
  const bin=join(evidence,"bin");mkdirSync(bin);
  // Keep actual owned-process metadata. Replace unrelated negative-UID rows
  // with one independent macOS nobody example, regardless of host daemons.
  writeFileSync(join(bin,"ps"),`#!/usr/bin/env python3
import subprocess,sys
r=subprocess.run(['/bin/ps',*sys.argv[1:]],capture_output=True,text=True)
for line in r.stdout.splitlines():
    fields=line.split()
    if len(fields)>3 and fields[3].lstrip('-').isdigit() and int(fields[3])<0: continue
    print(line)
print('2147483000 1 2147483000 -2 Sun Oct 4 12:00:00 2026 /unrelated/nobody-process')
sys.exit(r.returncode)
`,{mode:0o700});
  const priorPath=process.env.PATH;
  try {
    process.env.PATH=bin+":"+priorPath;
    registerOwnedBrowserServer({process:()=>child},evidence,nonce,{launcher:process.execPath});
    const registry=JSON.parse(readFileSync(join(evidence,"startup-process-registry.json"),"utf8"));
    assert.equal(registry.browserGroup,child.pid);
    assert.equal(registry.uid,process.getuid());
    assert.ok(registry.entries.some(entry=>entry.pid===child.pid));
    assert.ok(registry.entries.every(entry=>entry.group===child.pid && entry.uid===process.getuid()));
    assert.equal(registry.entries.some(entry=>entry.pid===2147483000),false);
  } finally {process.env.PATH=priorPath;}
}));


async function scriptFixture(check) {
  const evidence=mkdtempSync(join(tmpdir(),"share-script-registry-test-"));
  const launcher=join(evidence,"cached-launcher.sh");
  // Same reviewed launcher relationship, with disposable Node as the native child.
  writeFileSync(launcher,`#!/usr/bin/env bash\n"${process.execPath}" -e 'console.log("READY");setInterval(()=>{},1000)' &\nwait\n`,{mode:0o700});
  const child=spawn(launcher,[],{detached:true,stdio:["ignore","pipe","ignore"]});
  await once(child.stdout,"data");
  try {await check({evidence,launcher,child});}
  finally {process.kill(-child.pid,"SIGKILL");await once(child,"exit");rmSync(evidence,{recursive:true,force:true});}
}

test("script registry requires pinned launch bytes plus exact direct native child",async()=>scriptFixture(async({evidence,launcher,child})=>{
  registerOwnedBrowserServer({process:()=>child},evidence,nonce,{launcher,runtimeExecutable:process.execPath});
  const registry=JSON.parse(readFileSync(join(evidence,"startup-process-registry.json"),"utf8"));
  assert.equal(registry.canonicalExecutable,realpathSync("/bin/bash"));
  assert.equal(registry.launcher.path,realpathSync(launcher));
  assert.ok(registry.entries.some(entry=>entry.parent===child.pid && entry.executable===registry.nativeRuntime.path));
}));

test("script interpreter alone cannot qualify an unrelated native runtime",async()=>scriptFixture(async({evidence,launcher,child})=>{
  assert.throws(()=>registerOwnedBrowserServer({process:()=>child},evidence,nonce,{launcher,runtimeExecutable:"/bin/echo"}),/exact cached native runtime/);
  assert.equal(existsSync(join(evidence,"startup-process-registry.json")),false);
}));
