// Public HTTP/browser deadline acceptance: actual 60-second wall time, no injected clock or timeout override.
import assert from "node:assert/strict";
import { createServer } from "node:http";
const pause = ms => new Promise(resolve => setTimeout(resolve,ms));
export async function verifyMixtapeTimeouts({browser, serviceBase, id, fragment, receipt, disposalOnly=false}) {
  const cases = disposalOnly ? ["events.dispose"] : ["details", "admission", "audio"].flatMap(stage => ["headers", "body", "drip"].map(kind => `${stage}.${kind}`));
  const observed = new Map(cases.map(name => [name, {name, admissions:0, tracks:0, start:null, close:null, chunks:0}]));
  const sockets = new Set(), timers = new Set(), contexts = [];
  const proxy = createServer(async (request,response) => {
    const name = request.headers["x-fixture-case"], record = observed.get(name);
    const path = request.url.split("?")[0];
    if (record && path.endsWith("/sessions")) record.admissions++;
    if (record && path.includes("/tracks/")) record.tracks++;
    try {
      const body = [];
      for await (const bytes of request) body.push(bytes);
      const headers = {...request.headers}; delete headers.host; delete headers["x-fixture-case"];
      const upstream = await fetch(serviceBase + request.url, {method:request.method,headers,body:body.length ? Buffer.concat(body) : undefined});
      const bytes = Buffer.from(await upstream.arrayBuffer());
      const forwarded = Object.fromEntries(upstream.headers); delete forwarded["transfer-encoding"]; delete forwarded.connection;
      const stage = name?.split(".")[0], kind = name?.split(".")[1];
      const target = stage === "details" ? path === `/v1/share/m/${id}` : stage === "admission" ? path.endsWith("/sessions") : stage === "audio" ? path.includes("/tracks/") : stage === "events" ? path.endsWith("/events") : false;
      if (record && target) {
        record.start = performance.now();
        response.on("close", () => {record.close=performance.now();});
        if (kind !== "headers" && kind !== "dispose") { response.writeHead(upstream.status,forwarded); response.write(bytes.subarray(0,1)); record.chunks++; }
        if (kind === "drip") {
          let offset=1;
          const timer=setInterval(() => {
            if (!response.destroyed && offset < bytes.length-1) {response.write(bytes.subarray(offset,++offset));record.chunks++;}
          },2000);
          timers.add(timer); response.on("close",()=>{clearInterval(timer);timers.delete(timer);});
        }
      } else {response.writeHead(upstream.status,forwarded);response.end(bytes);}
    } catch { if (!response.destroyed) {response.writeHead(502);response.end();} }
  });
  proxy.on("connection", socket => {sockets.add(socket);socket.on("close",()=>sockets.delete(socket));});
  await new Promise(resolve => proxy.listen(0,"127.0.0.1",resolve));
  const base = `http://127.0.0.1:${proxy.address().port}`;
  receipt.timedCases = [];
  try {
    const results = await Promise.allSettled(cases.map(async name => {
      const record = observed.get(name);
      const context = await browser.newContext({extraHTTPHeaders:{"X-Fixture-Case":name}}); contexts.push(context);
      const page = await context.newPage();
      const errors=[]; page.on("pageerror",()=>errors.push("script error"));
      await page.addInitScript(() => {
        window.__createdBlobs=0;window.__csp=[];
        document.addEventListener("securitypolicyviolation",event=>window.__csp.push(event.violatedDirective));
        const create=URL.createObjectURL.bind(URL);URL.createObjectURL=blob=>{window.__createdBlobs++;return create(blob);};
      });
      let passed=false;
      try {
        await page.goto(`${base}/m/${id}#${fragment}`);
        if (!name.startsWith("details.")) {await page.locator("#player").waitFor({state:"visible"});await page.locator("#play").click();}
        if (disposalOnly) {
          for (let i=0;record.start===null && i<30;++i) await pause(50);
          assert.ok(record.start !== null,"owned authenticated analytics request reached the public endpoint");
          await page.goto(base + "/health");
          await pause(700);
          assert.ok(record.close !== null,"page disposal cancels the owned analytics request");
          assert.equal(record.admissions,1);assert.equal(record.tracks,1);assert.deepEqual(errors,[]);
          passed=true; return;
        }
        await page.waitForFunction(() => document.body.dataset.state === "failed" || !document.getElementById("admission").hidden,null,{timeout:66000});
        const elapsed=performance.now()-record.start;
        assert.ok(record.start !== null && elapsed >= 59000 && elapsed <= 65000,`absolute resource wall clock ${name}: ${Math.round(elapsed)}ms`);
        const status=await page.locator("#status").textContent();
        assert.ok(status.includes("minute") || status.includes("retry"),"accessible timeout/retry status");
        assert.equal(await page.evaluate(()=>window.__createdBlobs),0,"no partial audio becomes a playable Blob");
        assert.equal(await page.locator("#audio").evaluate(audio=>audio.currentTime),0);
        assert.equal(record.admissions,name.startsWith("details.") ? 0 : 1,"no silent admission retry");
        assert.equal(record.tracks,name.startsWith("audio.") ? 1 : 0);
        if (name.endsWith(".drip")) assert.ok(record.chunks>=20,"actual slow-drip delivery was observed");
        await pause(300);
        assert.ok(record.close !== null,"timed-out HTTP response is canceled");
        assert.deepEqual(errors,[]);assert.deepEqual(await page.evaluate(()=>window.__csp),[]);
        passed=true;
      } finally {
        receipt.timedCases.push({name,outcome:passed ? "PASS":"FAIL",elapsedMilliseconds:record.start===null ? null:Math.round(performance.now()-record.start),admissions:record.admissions,tracks:record.tracks,chunks:record.chunks,connectionClosed:record.close!==null,status:await page.evaluate(()=>document.getElementById("status")?.textContent ?? null).catch(()=>null)});
        await context.close();
      }
    }));
    receipt[disposalOnly ? "disposalCounts" : "timeoutCounts"]={executed:results.length,passed:results.filter(r=>r.status==="fulfilled").length,failed:results.filter(r=>r.status==="rejected").length,skipped:0};
    for (const result of results) if(result.status==="rejected") throw result.reason;
  } finally {
    await Promise.allSettled(contexts.map(context=>context.close()));
    for (const timer of timers) clearInterval(timer);
    for (const socket of sockets) socket.destroy();
    await new Promise(resolve=>proxy.close(resolve));
    receipt.ownedDeadlineProxyExited=true;
  }
}
