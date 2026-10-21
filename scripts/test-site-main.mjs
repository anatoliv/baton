// Runs website/main.js in a stubbed browser and presses the hero demo's Play button.
// Guards the ?patch= lookup: an inherited name such as "constructor" must fall back to
// the default voicing rather than reach the audio graph with undefined settings
// (TBX-1000000480). Run: node --test scripts/test-site-main.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('../website/main.js', import.meta.url), 'utf8');

// A value that absorbs any property read or call, so the page's DOM work is a no-op.
function absorber() {
  const target = function () {};
  return new Proxy(target, {
    get(_, key) {
      if (key === Symbol.toPrimitive) return () => 0;
      if (key === 'then') return undefined;
      if (key === 'length') return 0;
      return absorber();
    },
    set() { return true; },
    apply() { return absorber(); },
    construct() { return absorber(); },
  });
}

function element(handlers, id) {
  const el = absorber();
  return new Proxy(el, {
    get(target, key) {
      if (key === 'addEventListener') return (type, fn) => { handlers[`${id}:${type}`] = fn; };
      if (key === 'querySelectorAll') return () => [];
      if (key === 'querySelector') return () => element(handlers, 'child');
      return Reflect.get(target, key);
    },
    set() { return true; },
  });
}

class FakeAudioContext {
  constructor() { this.sampleRate = 48000; this.currentTime = 0; this.state = 'running'; this.destination = absorber(); }
  // Browsers refuse a zero or non-numeric length; this is what broke on Play.
  createBuffer(channels, length, rate) {
    if (!Number.isInteger(length) || length <= 0) throw new Error(`NotSupportedError: buffer length ${length}`);
    return { getChannelData: () => new Float32Array(length) };
  }
}
for (const name of ['createGain', 'createDynamicsCompressor', 'createAnalyser', 'createConvolver',
  'createBiquadFilter', 'createOscillator', 'createStereoPanner', 'createDelay', 'createBufferSource']) {
  FakeAudioContext.prototype[name] = function () { return absorber(); };
}

function runPage(search) {
  const handlers = {};
  const document = new Proxy(absorber(), {
    get(target, key) {
      if (key === 'getElementById') return id => element(handlers, id);
      if (key === 'querySelector') return sel => element(handlers, sel);
      if (key === 'querySelectorAll') return () => [];
      if (key === 'addEventListener') return (type, fn) => { handlers[`document:${type}`] = fn; };
      if (key === 'documentElement') return element(handlers, 'root');
      if (key === 'hidden') return false;
      return Reflect.get(target, key);
    },
  });
  const window = { AudioContext: FakeAudioContext, matchMedia: () => ({ matches: true, addEventListener() {} }) };
  const context = vm.createContext({
    window, document, location: { search }, URLSearchParams,
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
    requestAnimationFrame: () => 1, cancelAnimationFrame() {},
    setInterval: () => 1, clearInterval() {}, setTimeout: () => 1, clearTimeout() {},
    CustomEvent: class { constructor(type, init) { this.type = type; this.detail = init && init.detail; } },
    IntersectionObserver: class { observe() {} unobserve() {} disconnect() {} },
    getComputedStyle: () => absorber(),
  });
  vm.runInContext(source, context, { filename: 'website/main.js' });
  return handlers;
}

for (const search of ['', '?patch=bright', '?patch=nonsense', '?patch=constructor', '?patch=__proto__', '?patch=toString']) {
  test(`hero demo plays with search "${search}"`, () => {
    const handlers = runPage(search);
    const play = handlers['hero-play:click'];
    assert.equal(typeof play, 'function', 'the Play button is wired');
    assert.doesNotThrow(() => play());
  });
}
