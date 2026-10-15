import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {writeFileSync} from 'node:fs';
import {join} from 'node:path';

// Real browser decoder errors, followed by explicit retry of the retained decrypted MP3.
// Only the test Audio source setter substitutes invalid bytes once; no fake media clock.
export async function verifyMediaErrorRecovery({browser,link,api,id,evidence}) {
  const context = await browser.newContext();
  const problems=[];
  await context.addInitScript(() => {
    const OriginalAudio=window.Audio, src=Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype,'src');
    window.Audio=function(...args) {
      const audio=new OriginalAudio(...args); audio.muted=true;
      const badURL=URL.createObjectURL(new Blob(['not a valid MPEG audio stream'],{type:'audio/mpeg'}));
      let substitute=true;
      Object.defineProperty(audio,'src',{get(){return src.get.call(audio);},set(value){
        src.set.call(audio,substitute && String(value).startsWith('blob:') ? badURL : value);
        if(String(value).startsWith('blob:')) substitute=false;
      }});
      window.__fixtureAudio=audio; window.__fixtureBadMedia=badURL; window.__fixtureMediaErrors=[];
      audio.addEventListener('error',()=>window.__fixtureMediaErrors.push(audio.error?.code));
      return audio;
    };
    window.Audio.prototype=OriginalAudio.prototype;Object.setPrototypeOf(window.Audio,OriginalAudio);
  });
  const page=await context.newPage();
  page.on('pageerror',e=>problems.push(String(e)));
  page.on('console',message=>{if(message.type()==='error') problems.push(message.text());});
  let stats,assets;
  try {
    await page.goto(link);
    const playerPath=await page.getAttribute('script[type="module"]','src');
    const assetResponse=await fetch(new URL(playerPath,link));
    const playerSource=await assetResponse.text();
    assert.ok(playerSource.includes('mediaFailed') && playerSource.includes('Tap play to try again.'), 'service serves the recovery change');
    assert.equal(assetResponse.headers.get('cache-control'),'public, no-cache');
    const version=new URL(playerPath,link).searchParams.get('v');
    assert.match(version,/^[0-9a-f]{10}$/);
    assert.ok(playerSource.includes(`./share-crypto.mjs?v=${version}`),'crypto import uses same content version');
    assets={version,servedPlayerSHA256:createHash('sha256').update(playerSource).digest('hex')}; await page.waitForSelector('#player:not([hidden])');
    await page.click('#play');
    const failed=async()=>{
      await page.waitForFunction(()=>window.__fixtureAudio.error && document.getElementById('status').textContent.includes('try again'));
      assert.equal(await page.evaluate(()=>document.body.classList.contains('is-playing')),false);
      assert.equal(await page.getAttribute('#play','aria-label'),'Play');
      assert.equal(await page.isVisible('#after'),false);
      // Error-latched queued events must not invent completion or restart the active UI.
      await page.evaluate(()=>{window.__fixtureAudio.dispatchEvent(new Event('timeupdate'));window.__fixtureAudio.dispatchEvent(new Event('ended'));});
      assert.equal(await page.isVisible('#after'),false);
    };
    await failed();
    const retry=async()=>{
      await page.click('#play');
      await page.waitForFunction(()=>window.__fixtureAudio.currentTime>1 && !window.__fixtureAudio.error && document.body.classList.contains('is-playing'),null,{timeout:15000});
      assert.equal(await page.textContent('#status'),'');
    };
    await retry();
    // Also fail after real playback has started, as the observed renderer failure did.
    await page.evaluate(()=>{window.__fixtureAudio.src=window.__fixtureBadMedia;window.__fixtureAudio.load();window.__fixtureAudio.play().catch(()=>{});});
    await failed(); await retry();
    await page.evaluate(()=>window.__fixtureAudio.pause());
    for(let attempt=0;attempt<30;attempt++) {
      stats=(await api('GET','/v1/share/shares')).json.shares.find(share=>share.id===id).stats;
      if(stats.plays===1 && stats.listeners===1) break;
      await page.waitForTimeout(100);
    }
    assert.equal(stats.fetches,1,'retries reuse one decrypted blob');
    assert.equal(stats.plays,1,'one listening session across both retries');
    assert.equal(stats.listeners,1);
    assert.equal(stats.completed,0,'errors and queued ended never become completion');
    assert.equal(stats.listened30s,0);
    const observed=await page.evaluate(()=>({errors:window.__fixtureMediaErrors,currentTime:window.__fixtureAudio.currentTime,readyState:window.__fixtureAudio.readyState,error:window.__fixtureAudio.error?.code ?? null,muted:window.__fixtureAudio.muted}));
    assert.equal(observed.errors.length,2); assert.ok(observed.errors.every(code=>code>0));
    assert.equal(observed.error,null);assert.ok(observed.currentTime>1);assert.equal(observed.readyState,4);
    assert.deepEqual(problems,[],'no CSP or script errors');
    // WebKit screenshot tools inject styles that CSP rejects: verify behavior first.
    await page.screenshot({path:join(evidence,'media-error-retried.png')});
    const screenshotErrors=[...problems];
    writeFileSync(join(evidence,'media-errors.json'),JSON.stringify({passed:true,physicalOutputMuted:true,observed,stats,assets,browserErrors:[],screenshotErrors},null,2));
    return screenshotErrors;
  } catch(error) {
    const observed=await page.evaluate(()=>({errors:window.__fixtureMediaErrors,currentTime:window.__fixtureAudio?.currentTime,readyState:window.__fixtureAudio?.readyState,error:window.__fixtureAudio?.error?.code ?? null,playing:document.body.classList.contains('is-playing'),status:document.getElementById('status')?.textContent})).catch(()=>null);
    writeFileSync(join(evidence,'media-errors.json'),JSON.stringify({passed:false,physicalOutputMuted:true,observed,stats,assets,browserErrors:problems,error:String(error.message).split(link).join('[redacted link]')},null,2));
    throw error;
  } finally {await context.close();}
}
