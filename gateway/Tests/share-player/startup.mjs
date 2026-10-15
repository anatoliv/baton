// Measurement only: observes the shipping whole-file pipeline; never changes its crypto/bytes.
import assert from "node:assert/strict";
import {createHash} from "node:crypto";
import {execFileSync} from "node:child_process";
import {readFileSync,realpathSync,writeFileSync} from "node:fs";
import {join} from "node:path";

// The registry is written before context/page setup, so a later Node crash still
// leaves the supervisor a precise browser-group identity. It stores no arguments.
export async function registerOwnedBrowser(browser,evidence,runID,expectedExecutable) {
  assert.match(runID ?? "",/^[a-f0-9]{32}$/,"startup requires its outer watchdog run ID");
  const session=await browser.newBrowserCDPSession();
  try {
    const {processInfo}=await session.send("SystemInfo.getProcessInfo");
    const root=processInfo.find(process=>process.type==="browser");
    assert.ok(root && Number.isInteger(root.id) && root.id>0);
    const expectedCanonical=realpathSync(expectedExecutable);
    const ids=processInfo.map(process=>process.id).filter(id=>Number.isInteger(id)&&id>0);
    const lines=execFileSync("ps",["-p",ids.join(","),"-o","pid=,pgid=,uid=,lstart=,comm="],{encoding:"utf8"});
    const entries=lines.trim().split("\n").map(line=>{
      const match=line.match(/^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\S+\s+\S+\s+\S+\s+\S+\s+\S+)\s+(.+)$/);
      assert.ok(match,"owned process fingerprint readable");
      return {pid:Number(match[1]),group:Number(match[2]),uid:Number(match[3]),started:match[4],executable:match[5]};
    }).filter(entry=>entry.group===root.id && entry.uid===process.getuid());
    assert.ok(entries.some(entry=>entry.pid===root.id && realpathSync(entry.executable)===expectedCanonical),"browser group/executable identity matches explicit cached runtime");
    writeFileSync(join(evidence,"startup-process-registry.json"),JSON.stringify({runID,browserGroup:root.id,
      uid:process.getuid(),expectedExecutable:entries.find(entry=>entry.pid===root.id).executable,
      requestedExecutable:expectedExecutable,canonicalExecutable:expectedCanonical,entries},null,2),{mode:0o600});
  } finally {await session.detach();}
}

// launchServer().process() is the public spawned ChildProcess, independent of
// engine/CDP. A script launcher qualifies only with its pinned bytes and an
// exact native runtime direct child in that same UID/group.
export function registerOwnedBrowserServer(server,evidence,runID,{launcher,runtimeExecutable=launcher}) {
  assert.match(runID ?? "",/^[a-f0-9]{32}$/);
  const child=server.process();
  assert.ok(Number.isInteger(child.pid) && child.pid>0);
  const launchCanonical=realpathSync(launcher), runtimeCanonical=realpathSync(runtimeExecutable);
  assert.equal(realpathSync(child.spawnfile),launchCanonical,"public spawned executable equals selected cached launcher");
  const launchBytes=readFileSync(launchCanonical);
  const isScript=launchBytes.subarray(0,2).toString()==="#!";
  let rootExpected=launchCanonical;
  if (isScript) {
    assert.match(launchBytes.toString(),/^#!\/usr\/bin\/env bash\n/,"only the reviewed cached WebKit bash launcher is supported");
    assert.notEqual(runtimeCanonical,launchCanonical,"script requires an explicit native runtime");
    rootExpected=realpathSync("/bin/bash");
  }
  const lines=execFileSync("ps",["-axo","pid=,ppid=,pgid=,uid=,lstart=,comm="],{encoding:"utf8",timeout:1000});
  const entries=lines.trim().split("\n").map(line=>{
    const match=line.match(/^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\S+\s+\S+\s+\S+\s+\S+\s+\S+)\s+(.+)$/);
    assert.ok(match,"process metadata readable");
    return {pid:Number(match[1]),parent:Number(match[2]),group:Number(match[3]),uid:Number(match[4]),started:match[5],executable:match[6]};
  }).filter(entry=>entry.group===child.pid && entry.uid===process.getuid());
  const exactExecutable=entry=>{
    if(entry.executable.startsWith("/")) return realpathSync(entry.executable);
    // macOS ps may return only "bash" for an env/shebang launcher. Query the
    // kernel path for this already-owned PID; never resolve a basename via PATH.
    assert.equal(process.platform,"darwin","absolute executable identity required");
    const path=execFileSync("python3",["-c", "import ctypes,sys; lib=ctypes.CDLL('/usr/lib/libproc.dylib'); buf=ctypes.create_string_buffer(4096); n=lib.proc_pidpath(int(sys.argv[1]),buf,len(buf)); sys.exit(1) if n<=0 else print(buf.value.decode())",String(entry.pid)],{encoding:"utf8",timeout:1000}).trim();
    entry.reportedExecutable=entry.executable;
    entry.executable=realpathSync(path);
    return entry.executable;
  };
  const root=entries.find(entry=>entry.pid===child.pid);
  if(root) exactExecutable(root);
  if(isScript) for(const entry of entries.filter(entry=>entry.parent===child.pid)) exactExecutable(entry);
  assert.ok(root && realpathSync(root.executable)===rootExpected,"exact launched group root matches selected runtime/interpreter");
  if(isScript) assert.ok(entries.some(entry=>entry.parent===child.pid && realpathSync(entry.executable)===runtimeCanonical),
    "pinned script has its exact cached native runtime as direct child");
  writeFileSync(join(evidence,"startup-process-registry.json"),JSON.stringify({runID,browserGroup:child.pid,
    uid:process.getuid(),expectedExecutable:root.executable,requestedExecutable:launcher,canonicalExecutable:rootExpected,
    launcher:{path:launchCanonical,sha256:createHash("sha256").update(launchBytes).digest("hex")},
    nativeRuntime:{path:runtimeCanonical,sha256:createHash("sha256").update(readFileSync(runtimeCanonical)).digest("hex")},
    ownershipSource:"Playwright launchServer().process() before connect",entries},null,2),{mode:0o600});
}

export async function measureStartup({browser,context,page,link,evidence,problems,profile,launch}) {
  const browserCDP = await browser.newBrowserCDPSession();
  const cdp = await context.newCDPSession(page);
  const version = await browserCDP.send("Browser.getVersion");
  const processRegistry = JSON.parse(readFileSync(join(evidence,"startup-process-registry.json"),"utf8"));
  const decoder = [], memory = [];
  for (const event of ["Media.playerEventsAdded","Media.playerErrorsRaised","Media.playerMessagesLogged","Media.playerPropertiesChanged"])
    cdp.on(event, value => decoder.push({event,value}));
  await cdp.send("Media.enable");
  await cdp.send("Network.enable");
  if (profile.downloadMbps || profile.latencyMs) await cdp.send("Network.emulateNetworkConditions", {
    offline:false, latency:profile.latencyMs, downloadThroughput:profile.downloadMbps ? profile.downloadMbps*1e6/8 : -1,
    uploadThroughput:-1, connectionType:"cellular4g",
  });
  await context.addInitScript(() => {
    const data = {click:null,fetchHeaders:null,resource:null,decryptFirst:null,decryptLast:null,
      decryptCount:0,blob:null,firstClock:null,maxTimerGap:0,events:[]};
    const instances = [];
    const NativeAudio = window.Audio;
    window.Audio = function(...args) {
      const audio = new NativeAudio(...args); instances.push(audio);
      for (const type of ["loadstart","loadedmetadata","canplay","play","playing","pause","waiting","stalled","error","ended"])
        audio.addEventListener(type, () => data.events.push({type,at:performance.now(),time:audio.currentTime,
          ready:audio.readyState,paused:audio.paused,error:audio.error?.code ?? null}));
      return audio;
    };
    window.Audio.prototype = NativeAudio.prototype; Object.setPrototypeOf(window.Audio,NativeAudio);
    document.addEventListener("click", event => {
      if (event.target.closest?.("#play") && data.click === null) data.click = performance.now();
    }, true);
    const nativeFetch = window.fetch.bind(window);
    window.fetch = (...args) => nativeFetch(...args).then(response => {
      if (response.url.endsWith("/audio")) data.fetchHeaders = performance.now();
      return response;
    });
    new PerformanceObserver(list => {
      for (const entry of list.getEntries()) if (entry.name.endsWith("/audio")) data.resource = {
        start:entry.startTime,responseStart:entry.responseStart,end:entry.responseEnd,
        encodedBodySize:entry.encodedBodySize,decodedBodySize:entry.decodedBodySize,transferSize:entry.transferSize};
    }).observe({type:"resource",buffered:true});
    const nativeDecrypt = crypto.subtle.decrypt.bind(crypto.subtle);
    crypto.subtle.decrypt = (...args) => {
      if (data.click === null) return nativeDecrypt(...args);
      data.decryptFirst ??= performance.now(); data.decryptCount++;
      return nativeDecrypt(...args).finally(() => { data.decryptLast = performance.now(); });
    };
    const nativeObjectURL = URL.createObjectURL.bind(URL);
    URL.createObjectURL = blob => {
      if (blob.type === "audio/mpeg") data.blob = {at:performance.now(),size:blob.size};
      return nativeObjectURL(blob);
    };
    let last = performance.now();
    setInterval(() => {
      const now = performance.now(); data.maxTimerGap = Math.max(data.maxTimerGap,now-last); last=now;
      if (data.click !== null && data.firstClock === null && instances.some(audio => audio.currentTime >= .25)) data.firstClock = now;
    },50);
    window.__startupStop = () => instances.forEach(audio => audio.pause());
    window.__startupSnapshot = () => ({...data,visibility:document.visibilityState,media:instances.map(audio => ({
      currentTime:audio.currentTime,duration:audio.duration,readyState:audio.readyState,networkState:audio.networkState,
      paused:audio.paused,ended:audio.ended,error:audio.error?.code ?? null,blobSource:audio.currentSrc.startsWith("blob:")}))});
  });
  const started = performance.now();
  async function sample(stage) {
    const info = await browserCDP.send("SystemInfo.getProcessInfo");
    const ids = info.processInfo.map(process => process.id).filter(id => Number.isInteger(id) && id > 0);
    const rss = execFileSync("ps", ["-o","pid=,rss=","-p",ids.join(",")], {encoding:"utf8"}).trim().split("\n")
      .filter(Boolean).map(line => {const [pid,kib] = line.trim().split(/\s+/).map(Number); return {pid,kib};});
    memory.push({stage,atMs:performance.now()-started,heap:await cdp.send("Runtime.getHeapUsage"),
      processes:info.processInfo.map(({id,type}) => ({id,type,rssKiB:rss.find(row=>row.pid===id)?.kib ?? null})),
      aggregateRSSKiB:rss.reduce((sum,row)=>sum+row.kib,0)});
  }
  let interval, busy=false, failure=null, snapshot=null;
  try {
    await sample("blank");
    await page.goto(link);
    await page.waitForSelector("#player:not([hidden])");
    await sample("ready");
    interval = setInterval(async () => {
      if (busy) return; busy=true;
      try {await sample("playing-pipeline");} catch (error) { failure ??= String(error); }
      finally {busy=false;}
    },100);
    await page.click("#play");
    const timeout = Math.min(120000,30000+(profile.downloadMbps ? profile.sealedBytes*8/(profile.downloadMbps*1e6)*1000 : 0));
    await page.waitForFunction(() => window.__startupSnapshot().media.some(audio=>audio.currentTime >= 1),null,{timeout});
    await page.waitForTimeout(2000);
    snapshot = await page.evaluate(() => window.__startupSnapshot());
    assert.ok(snapshot.media[0].currentTime >= 2 && !snapshot.media[0].error,"decoded media clock continues advancing");
    assert.deepEqual(problems,[],"zero CSP/script errors");
    assert.equal(snapshot.blob.size,profile.plainBytes,"shipping player decrypts every source byte");
    assert.ok(snapshot.decryptCount > 0 && snapshot.decryptFirst > snapshot.click);
    assert.ok(snapshot.resource?.end <= snapshot.decryptFirst,"whole download precedes decryption");
    assert.equal(snapshot.resource.encodedBodySize,profile.sealedBytes,"browser received full sealed payload");
  } catch (error) {failure=String(error);} finally {
    clearInterval(interval);
    while(busy) await new Promise(resolve=>setTimeout(resolve,10));
    snapshot ??= await page.evaluate(() => window.__startupSnapshot()).catch(()=>null);
    await sample("final").catch(error=>{failure ??= String(error);});
    await page.evaluate(() => window.__startupStop?.()).catch(()=>{});
    const baseline=memory.find(sample=>sample.stage==="ready");
    const relative = value => value != null && snapshot?.click != null ? value-snapshot.click : null;
    const result = {profile,version,processRegistry,requestedLaunch:launch,actualCommandLineAvailable:false,
      commandLineLimitation:"Browser.getBrowserCommandLine requires --enable-automation; no diagnostic flag added",
      physicalOutputMuted:null,expectedPhysicalOutputMute:true,
      muteAttribution:"Installed Playwright headless defaults supply --mute-audio; source-derived, not measured/returned by CDP",
      passed:failure===null,error:failure,browserErrors:problems,snapshot,
      timingMs:{headers:relative(snapshot?.fetchHeaders),download:relative(snapshot?.resource?.end),
        decryptStarted:relative(snapshot?.decryptFirst),decryptFinished:relative(snapshot?.decryptLast),
        decryptWall:snapshot?.decryptLast != null ? snapshot.decryptLast-snapshot.decryptFirst : null,
        blobReady:relative(snapshot?.blob?.at),firstAdvancingClock:relative(snapshot?.firstClock)},
      memory:{samples:memory,readyRSSKiB:baseline?.aggregateRSSKiB ?? null,peakRSSKiB:memory.length ? Math.max(...memory.map(sample=>sample.aggregateRSSKiB)) : null,
        peakRSSDeltaKiB:baseline ? Math.max(...memory.map(sample=>sample.aggregateRSSKiB))-baseline.aggregateRSSKiB : null},
      limitations:["local synthetic service, not a real device/LTE measurement","first clock >=0.25s is decoder progress, not physical sound",
        "process RSS includes browser/renderer/audio services and caches; heap alone excludes native buffers",
        "100ms samples can miss brief allocations; no forced GC; instrumented single run is not p95"]};
    writeFileSync(join(evidence,"startup.json"),JSON.stringify(result,null,2));
    writeFileSync(join(evidence,"startup-decoder.json"),JSON.stringify(decoder,null,2).split(link).join("[synthetic-local-link]"));
  }
  assert.equal(failure,null,"startup evidence retained on failure");
}
