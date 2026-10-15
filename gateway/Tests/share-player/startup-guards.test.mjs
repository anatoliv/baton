// Guard checks launch no browser/service/ffmpeg and use no external account/config.
import {test} from "node:test";
import assert from "node:assert/strict";
import {spawnSync} from "node:child_process";
import {existsSync,mkdtempSync,rmSync} from "node:fs";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {fileURLToPath} from "node:url";
const runner=fileURLToPath(new URL("./e2e.mjs",import.meta.url));
for (const [name,flags,environment,message] of [
  ["public",["--startup-only","--public"],{},"standalone local Chromium"],
  ["external localhost",["--startup-only"],{SHARE_E2E_SERVICE:"http://127.0.0.1:1"},"own synthetic localhost service"],
  ["external public",["--startup-only"],{SHARE_E2E_PUBLIC:"https://example.invalid"},"standalone local Chromium"],
  ["listener load",["--startup-only","--nginx-docker","--listeners=50"],{},"standalone local Chromium"],
  ["media substitution",["--startup-only","--media-errors-only"],{},"standalone local Chromium"],
  ["oversized fixture",["--startup-only","--song-seconds=801"],{},"40..800s"],
  ["unmeasured duration override",["--song-seconds=400"],{},"40..800s"],
  ["unsupported channel",["--chromium-channel=chrome"],{},"cached full Chromium"],
]) test(`refuses ${name} before creating any fixture/evidence`,()=>{
  const work=mkdtempSync(join(tmpdir(),"share-startup-guard-")),evidence=join(work,"evidence");
  try {
    const result=spawnSync(process.execPath,[runner,...flags,"/invalid/not-a-service",evidence],{
      encoding:"utf8",env:{PATH:"/usr/bin:/bin",HOME:work,...environment}});
    assert.notEqual(result.status,0);assert.match(result.stderr,new RegExp(message.replace(/[.*+?^${}()|[\]\\]/g,"\\$&")));
    assert.equal(existsSync(evidence),false);assert.doesNotMatch(result.stdout,/making .* MP3|starting .* on/);
  } finally {rmSync(work,{recursive:true,force:true});}
});
