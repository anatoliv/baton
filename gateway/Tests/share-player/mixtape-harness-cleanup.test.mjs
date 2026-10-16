import assert from "node:assert/strict";
import { test } from "node:test";
import { spawn, execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync, readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
const binary = process.argv[2];
assert.ok(binary?.startsWith("/private/tmp/"), "requires owned local fixture binary");
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
test("CLI generation failure terminates its exact owned fixture and writes sanitized failure receipt", async () => {
  const work = mkdtempSync("/private/tmp/baton-mixtape-cleanup-");
  const pidFile = join(work,"fixture.pid"), portFile = join(work,"fixture.port"), wrapper = join(work,"fixture-wrapper"), fail = join(work,"generator-fails");
  const quote = value => "'" + value.replaceAll("'", "'\\''") + "'";
  writeFileSync(wrapper, `#!/bin/sh\nprintf '%s\\n' "$$" > ${quote(pidFile)}\nprintf '%s\\n' "$2" > ${quote(portFile)}\nexec ${quote(binary)} "$@"\n`, {mode:0o700});
  writeFileSync(fail, "#!/bin/sh\nsleep 0.4\nexit 1\n", {mode:0o700});
  const evidence = join(work,"evidence");
  const child = spawn(process.execPath,[new URL("./mixtape-e2e.mjs",import.meta.url).pathname,wrapper,evidence,fail,"chromium","safety"], {stdio:["ignore","pipe","pipe"]});
  let output = ""; child.stdout.on("data", d => output += d); child.stderr.on("data", d => output += d);
  const code = await new Promise(resolve => child.on("exit",resolve));
  let pid;
  try {
    assert.notEqual(code,0);
    assert.ok(existsSync(pidFile), "fixture process was created");
    pid = Number(readFileSync(pidFile,"utf8"));
    const port = Number(readFileSync(portFile,"utf8"));
    let alive; try { process.kill(pid,0); alive=true; } catch { alive=false; }
    let listening; try { listening=(await fetch(`http://127.0.0.1:${port}/health`)).ok; } catch { listening=false; }
    const resultPath = join(evidence,"result.json");
    const observed = {harnessExit:code, ownedPID:pid, ownedPIDAlive:alive, portListening:listening, failureReceiptExists:existsSync(resultPath)};
    writeFileSync(join(work,"cleanup-observation.json"),JSON.stringify(observed,null,2)+"\n");
    console.log(`cleanup observation: ${JSON.stringify(observed)}`);
    assert.equal(alive,false,"owned fixture PID must exit after setup failure");
    assert.equal(listening,false,"owned fixture port must refuse after setup failure");
    assert.ok(existsSync(resultPath),"sanitized failure receipt exists");
    const receipt=JSON.parse(readFileSync(resultPath));
    assert.equal(receipt.outcome,"FAIL"); assert.equal(receipt.ownedServiceExited,true);
    assert.equal(receipt.counts.executed,0); assert.equal(receipt.failureStage,"material generation");
    assert.ok(!JSON.stringify(receipt).includes('"ownerToken"') && !JSON.stringify(receipt).includes('"rootKey"'));
  } finally {
    // RED cleanup may stop only the exact PID minted by this test's wrapper.
    if (pid) {
      let alive; try { process.kill(pid,0); alive=true; } catch { alive=false; }
      if (alive) {
        const command=execFileSync("ps",["-p",String(pid),"-o","comm="],{encoding:"utf8"}).trim();
        assert.ok(command.includes("baton-share-fixture"),"RED cleanup refuses unknown process identity");
        process.kill(pid,"SIGTERM");
        await pause(100);
      }
    }
  }
});
