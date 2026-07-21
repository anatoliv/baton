/* Baton — baton.tonebox.io
   Progressive enhancement only: theme toggle + scroll reveals.
   No dependencies, no network requests. */
(function () {
  "use strict";

  /* ---------- Theme toggle ---------- */
  var root = document.documentElement;
  var toggle = document.getElementById("theme-toggle");
  var themeColor = document.getElementById("theme-color");

  function currentTheme() {
    var explicit = root.getAttribute("data-theme");
    if (explicit === "light" || explicit === "dark") return explicit;
    return "dark"; // dark is the default
  }

  function syncThemeColor(theme) {
    if (themeColor) themeColor.setAttribute("content", theme === "light" ? "#faf6f0" : "#171310");
  }

  function applyTheme(theme) {
    syncThemeColor(theme);
    try {
      // Dark is the default. Persist only an explicit light choice; picking
      // dark forgets the preference so the site returns to its default.
      if (theme === "dark") {
        localStorage.removeItem("baton-theme");
        root.removeAttribute("data-theme");
      } else {
        root.setAttribute("data-theme", theme);
        localStorage.setItem("baton-theme", theme);
      }
    } catch (e) {
      /* storage unavailable — still reflect the choice for this session */
      root.setAttribute("data-theme", theme);
    }
    if (toggle) {
      toggle.setAttribute(
        "aria-label",
        theme === "dark" ? "Switch to light theme" : "Switch to dark theme"
      );
    }
  }

  syncThemeColor(currentTheme());

  if (toggle) {
    toggle.setAttribute(
      "aria-label",
      currentTheme() === "dark" ? "Switch to light theme" : "Switch to dark theme"
    );
    toggle.addEventListener("click", function () {
      applyTheme(currentTheme() === "dark" ? "light" : "dark");
    });
  }

  /* ---------- Scroll reveals ---------- */
  var reveals = Array.prototype.slice.call(document.querySelectorAll(".reveal"));
  var reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  if (!("IntersectionObserver" in window) || reduceMotion) {
    reveals.forEach(function (el) { el.classList.add("is-visible"); });
    return;
  }

  var observer = new IntersectionObserver(
    function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          entry.target.classList.add("is-visible");
          observer.unobserve(entry.target);
        }
      });
    },
    { rootMargin: "0px 0px -40px 0px", threshold: 0 }
  );

  // Anything already on screen (or above it) reveals synchronously, so the
  // first paint never depends on observer timing; the observer handles the rest.
  var vh = window.innerHeight || document.documentElement.clientHeight;
  reveals.forEach(function (el) {
    if (el.getBoundingClientRect().top < vh - 40) {
      el.classList.add("is-visible");
    } else {
      observer.observe(el);
    }
  });
})();

/* ---------- Hero: play a live-composed taste + reactive equalizer ----------
   A short original loop composed and rendered with the Web Audio API — a warm
   detuned-saw pad on a I–V–vi–IV progression, a soft bass, a plucky arpeggio for
   movement, and a melody line, run through a lowpass, a generated reverb, and a
   compressor. No audio file, no network, no autoplay (it starts only on a click),
   and no third-party copyright — the notes are written right here. An AnalyserNode
   drives the equalizer bars off the actual signal. */
(function () {
  "use strict";

  var stage = document.querySelector(".hero-stage");
  var btn = document.getElementById("hero-play");
  var label = stage && stage.querySelector(".hp-label");
  if (!stage || !btn) return;

  var AudioCtx = window.AudioContext || window.webkitAudioContext;
  if (!AudioCtx) { btn.hidden = true; if (label) label.hidden = true; return; }

  var bars = Array.prototype.slice.call(stage.querySelectorAll(".eq span"));

  /* --- The music: 10 short original loops (MIDI note numbers), each 4 bars. One is
     picked at random on load; force a specific one with ?piece=N (0–9) to audition.
     Each is a different key + progression, and every melody stays in its key's
     pentatonic over diatonic chords, so every pick lands consonant. All render
     through the warm voicing defined below. --- */
  var PIECES = [
    { name: "Meadow",     bpm: 84, chords: [[60,64,67],[55,59,62],[57,60,64],[53,57,60]], bass: [36,43,45,41], melody: {0:72,6:76,10:79,16:74,22:79,26:81,32:76,38:81,42:79,48:74,54:76,58:72} },
    { name: "Amber",      bpm: 78, chords: [[57,60,64],[53,57,60],[60,64,67],[55,59,62]], bass: [45,41,36,43], melody: {0:76,6:72,10:69,16:72,22:76,26:79,32:81,38:79,42:76,48:74,52:72,58:69} },
    { name: "Sweetheart", bpm: 88, chords: [[60,64,67],[57,60,64],[53,57,60],[55,59,62]], bass: [36,45,41,43], melody: {0:79,8:76,16:81,24:79,32:72,40:74,48:79,56:81} },
    { name: "Nocturne",   bpm: 76, chords: [[62,65,69],[58,62,65],[53,57,60],[60,64,67]], bass: [38,34,41,36], melody: {0:77,8:74,14:72,16:69,24:65,32:72,40:77,48:79,54:74,58:69} },
    { name: "Jazz Cafe",  bpm: 82, chords: [[60,64,67,71],[57,60,64,67],[62,65,69,72],[55,59,62,65]], bass: [36,45,38,43], melody: {0:76,8:79,12:76,16:72,20:74,24:72,32:74,38:77,42:74,48:79,54:76,58:72} },
    { name: "Clearing",   bpm: 86, chords: [[55,59,62],[62,66,69],[64,67,71],[60,64,67]], bass: [43,38,40,36], melody: {0:74,6:71,10:74,16:76,22:74,26:71,32:79,38:76,42:74,48:71,54:74,58:67} },
    { name: "Hopeful",    bpm: 90, chords: [[60,64,67],[64,67,71],[65,69,72],[67,71,74]], bass: [36,40,41,43], melody: {0:76,8:79,16:76,24:72,32:81,40:79,48:74,56:79} },
    { name: "Wistful",    bpm: 80, chords: [[57,60,64],[55,59,62],[53,57,60],[55,59,62]], bass: [45,43,41,43], melody: {0:72,6:69,10:67,16:79,22:76,26:74,32:72,38:69,42:67,48:76,54:72,58:69} },
    { name: "Warm Bath",  bpm: 82, chords: [[53,57,60],[60,64,67],[62,65,69],[58,62,65]], bass: [41,36,38,34], melody: {0:72,6:77,10:74,16:79,22:77,26:72,32:74,38:69,42:72,48:77,54:74,58:69} },
    { name: "Dreams",     bpm: 78, chords: [[64,67,71],[60,64,67],[55,59,62],[62,66,69]], bass: [40,36,43,38], melody: {0:76,8:74,14:71,16:79,22:76,26:74,32:71,40:74,44:69,48:79,54:76,58:71} }
  ];
  var wantPiece = new URLSearchParams(location.search).get("piece");
  var pieceIdx = (wantPiece != null && PIECES[+wantPiece]) ? +wantPiece : Math.floor(Math.random() * PIECES.length);
  var PIECE = PIECES[pieceIdx];
  var CHORDS = PIECE.chords, BASS = PIECE.bass, MELODY = PIECE.melody;
  stage.dataset.piece = PIECE.name;   // inspectable: which loop this load drew

  /* Two voicings of the same composition, kept side by side so they can be A/B'd:
     "warm" (default) rolls off the highs — lower pad cutoff, a rounder sine bass, the
     arpeggio dropped out of its bright octave, and a softer lowpass on the plucks.
     "bright" is the original voicing — reach it with ?patch=bright to compare. */
  var PATCHES = {
    warm:   { padType: "sawtooth", padCut: 900,  padQ: 0.7, detune: 8, bassType: "sine",     pluckType: "triangle", pluckCut: 2200, pluckAttack: 0.012, arpOct: 0,  arpGain: 0.05, melGain: 0.12, revReturn: 0.30, revLen: 2.8, revDecay: 2.8 },
    bright: { padType: "sawtooth", padCut: 1300, padQ: 0.6, detune: 7, bassType: "triangle", pluckType: "triangle", pluckCut: 9000, pluckAttack: 0.006, arpOct: 12, arpGain: 0.05, melGain: 0.13, revReturn: 0.26, revLen: 2.4, revDecay: 3.2 }
  };
  var wantPatch = new URLSearchParams(location.search).get("patch");
  var P = PATCHES[wantPatch] || PATCHES.warm;

  var BPM = PIECE.bpm;
  var STEPS = 64;                    // 4 bars × 16 sixteenth-notes
  var secPerStep = 60 / BPM / 4;
  var barDur = secPerStep * 16;
  var LOOKAHEAD = 0.1;               // schedule this far ahead (s)
  var TIMER_MS = 25;

  var ctx, master, comp, analyser, freqData, padFilter, pluckFilter, dryBus, reverb, reverbReturn;
  var playing = false, curStep = 0, nextStepTime = 0, schedId = null, raf = 0;

  function mtof(m) { return 440 * Math.pow(2, (m - 69) / 12); }

  // A cheap algorithmic reverb: an exponentially-decaying noise impulse response.
  function makeImpulse(seconds, decay) {
    var rate = ctx.sampleRate, len = Math.floor(rate * seconds);
    var buf = ctx.createBuffer(2, len, rate);
    for (var ch = 0; ch < 2; ch++) {
      var d = buf.getChannelData(ch);
      for (var i = 0; i < len; i++) d[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / len, decay);
    }
    return buf;
  }

  function ensureGraph() {
    if (ctx) return;
    ctx = new AudioCtx();

    master = ctx.createGain(); master.gain.value = 0;
    comp = ctx.createDynamicsCompressor();     // catch peaks so layers never clip
    analyser = ctx.createAnalyser(); analyser.fftSize = 128;
    freqData = new Uint8Array(analyser.frequencyBinCount);
    master.connect(comp); comp.connect(analyser); analyser.connect(ctx.destination);

    dryBus = ctx.createGain(); dryBus.gain.value = 1; dryBus.connect(master);
    reverb = ctx.createConvolver(); reverb.buffer = makeImpulse(P.revLen, P.revDecay);
    reverbReturn = ctx.createGain(); reverbReturn.gain.value = P.revReturn;
    reverb.connect(reverbReturn); reverbReturn.connect(master);

    padFilter = ctx.createBiquadFilter();      // warmth on the pad
    padFilter.type = "lowpass"; padFilter.frequency.value = P.padCut; padFilter.Q.value = P.padQ;
    padFilter.connect(dryBus); padFilter.connect(reverb);

    pluckFilter = ctx.createBiquadFilter();    // rounds the top off the arp + melody
    pluckFilter.type = "lowpass"; pluckFilter.frequency.value = P.pluckCut; pluckFilter.Q.value = 0.5;
    pluckFilter.connect(dryBus); pluckFilter.connect(reverb);
  }

  function env(param, t, peak, attack, dur, release) {
    param.setValueAtTime(0.0001, t);
    param.linearRampToValueAtTime(peak, t + attack);
    param.setValueAtTime(peak, t + Math.max(attack, dur - release));
    param.exponentialRampToValueAtTime(0.0001, t + dur);
  }

  function pad(midiTriad, t, dur) {
    midiTriad.forEach(function (m) {
      var g = ctx.createGain(); g.gain.value = 0.0001; g.connect(padFilter);
      [-P.detune, P.detune].forEach(function (cents) {   // two detuned voices = warmth
        var o = ctx.createOscillator();
        o.type = P.padType; o.frequency.value = mtof(m); o.detune.value = cents;
        o.connect(g); o.start(t); o.stop(t + dur + 0.1);
      });
      env(g.gain, t, 0.05, 0.35, dur, 0.7);
    });
  }

  function bass(m, t, dur) {
    var o = ctx.createOscillator(); o.type = P.bassType; o.frequency.value = mtof(m);
    var g = ctx.createGain(); g.gain.value = 0.0001; o.connect(g); g.connect(dryBus);
    env(g.gain, t, 0.14, 0.03, dur, dur * 0.4);
    o.start(t); o.stop(t + dur + 0.1);
  }

  function pluck(m, t, peak) {                    // short — arp + melody, softened by pluckFilter
    var o = ctx.createOscillator(); o.type = P.pluckType; o.frequency.value = mtof(m);
    var g = ctx.createGain(); g.gain.value = 0.0001;
    o.connect(g); g.connect(pluckFilter);
    g.gain.setValueAtTime(0.0001, t);
    g.gain.linearRampToValueAtTime(peak, t + P.pluckAttack);
    g.gain.exponentialRampToValueAtTime(0.0001, t + 0.35);
    o.start(t); o.stop(t + 0.42);
  }

  function scheduleStep(step, t) {
    var bar = Math.floor(step / 16) % 4;
    var s = step % 16;
    if (s === 0) {                                // new chord + bass on each downbeat
      pad(CHORDS[bar], t, barDur * 0.98);
      bass(BASS[bar], t, barDur * 0.96);
    }
    if (s % 2 === 0) {                            // eighth-note arpeggio
      pluck(CHORDS[bar][(step / 2) % 3] + P.arpOct, t, P.arpGain);
    }
    if (MELODY[step] != null) pluck(MELODY[step], t, P.melGain);
  }

  function scheduler() {
    while (nextStepTime < ctx.currentTime + LOOKAHEAD) {
      scheduleStep(curStep, nextStepTime);
      nextStepTime += secPerStep;
      curStep = (curStep + 1) % STEPS;
    }
  }

  function drawEQ() {
    analyser.getByteFrequencyData(freqData);
    var n = bars.length;
    var bin = Math.max(1, Math.floor(freqData.length / (n + 2)));
    for (var i = 0; i < n; i++) {
      var v = freqData[bin * (i + 1)] / 255;
      bars[i].style.transform = "scaleY(" + (0.18 + v * 0.95).toFixed(3) + ")";
    }
    raf = requestAnimationFrame(drawEQ);
  }

  function start() {
    ensureGraph();
    if (ctx.state === "suspended") ctx.resume();
    playing = true;
    curStep = 0;
    nextStepTime = ctx.currentTime + 0.12;
    master.gain.cancelScheduledValues(ctx.currentTime);
    master.gain.setValueAtTime(master.gain.value, ctx.currentTime);
    master.gain.linearRampToValueAtTime(0.9, ctx.currentTime + 0.4);
    scheduler();
    schedId = setInterval(scheduler, TIMER_MS);
    raf = requestAnimationFrame(drawEQ);
    stage.classList.add("is-playing");
    // Let the adaptive-color module recolor the hero to this piece's mood.
    stage.dispatchEvent(new CustomEvent("baton:play", { detail: { piece: PIECE.name } }));
    btn.setAttribute("aria-pressed", "true");
    btn.setAttribute("aria-label", "Pause the demo");
    if (label) label.textContent = "Now playing";
  }

  function stop() {
    playing = false;
    if (schedId) { clearInterval(schedId); schedId = null; }
    if (raf) { cancelAnimationFrame(raf); raf = 0; }
    if (master) {
      master.gain.cancelScheduledValues(ctx.currentTime);
      master.gain.setValueAtTime(master.gain.value, ctx.currentTime);
      master.gain.linearRampToValueAtTime(0.0001, ctx.currentTime + 0.3);
    }
    bars.forEach(function (b) { b.style.transform = ""; });
    stage.classList.remove("is-playing");
    stage.dispatchEvent(new CustomEvent("baton:stop"));
    btn.setAttribute("aria-pressed", "false");
    btn.setAttribute("aria-label", "Play a demo melody");
    if (label) label.textContent = "Play a taste";
  }

  btn.addEventListener("click", function () { playing ? stop() : start(); });

  // Don't keep playing into a backgrounded tab.
  document.addEventListener("visibilitychange", function () {
    if (document.hidden && playing) stop();
  });
})();

/* ---------- Adaptive "music" color ----------
   The site demonstrates the app's headline feature: the interface adapts to your
   music. A slow ambient cycle recolors the hero's waves/notes/glow through a
   curated palette; playing the live demo locks the color to the current piece's
   mood. Brand chrome (logo, nav, CTAs, links) stays Baton orange throughout.
   Everything here rides the --music custom property (registered in CSS so changes
   crossfade); under reduced motion the ambient cycle is skipped. */
(function () {
  "use strict";

  var root = document.documentElement;
  var stage = document.querySelector(".hero-stage");
  var reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var BRAND = "#E98345";

  // The design doc's sequence — Blue → Purple → Emerald → Orange (brand) → Rose.
  var PALETTE = ["#4F89FF", "#9A6CFF", "#1FB58C", BRAND, "#F0568C"];
  // Each demo loop leans to a mood, so playing a taste recolors to match it.
  var PIECE_HUE = {
    Meadow: 2, Amber: 3, Sweetheart: 4, Nocturne: 1, "Jazz Cafe": 3,
    Clearing: 2, Hopeful: 0, Wistful: 1, "Warm Bath": 3, Dreams: 1
  };

  function hexToRgb(h) {
    h = h.replace("#", "");
    return [parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16)];
  }
  function put(rgb) { root.style.setProperty("--music", "rgb(" + rgb[0] + "," + rgb[1] + "," + rgb[2] + ")"); }

  var i = 0, timer = null, locked = false, raf = 0, cur = hexToRgb(BRAND);

  // Crossfade --music to a target color frame-by-frame. A CSS transition on a
  // var()-derived property (stroke/color/background-color) doesn't animate in
  // Chrome/Safari when the custom property is what changes, so we interpolate here.
  function animateTo(hex, ms) {
    var to = hexToRgb(hex), from = cur.slice(), t0 = performance.now(), done = false;
    if (raf) cancelAnimationFrame(raf);
    if (reduce || !ms) { cur = to; put(to); return; }
    (function step(now) {
      var k = Math.min(1, (now - t0) / ms);
      var e = k < 0.5 ? 2 * k * k : 1 - Math.pow(-2 * k + 2, 2) / 2;   // easeInOut
      cur = [0, 1, 2].map(function (j) { return Math.round(from[j] + (to[j] - from[j]) * e); });
      put(cur);
      if (k < 1) raf = requestAnimationFrame(step); else done = true;
    })(t0);
    // Guarantee arrival even if rAF is throttled/paused (background or headless tab):
    // rAF gives the smooth crossfade when the tab paints; this snaps to the target otherwise.
    setTimeout(function () { if (!done) { cur = to; put(to); } }, ms + 80);
  }

  function tick() { if (!locked) { i = (i + 1) % PALETTE.length; animateTo(PALETTE[i], 2400); } }
  function run() { if (!timer) timer = setInterval(tick, 7000); }
  function halt() { if (timer) { clearInterval(timer); timer = null; } }

  if (stage) {
    // Playing the demo pins the hero to the current piece's mood (a quick fade)…
    stage.addEventListener("baton:play", function (e) {
      locked = true;
      var name = (e.detail && e.detail.piece) || "";
      var idx = PIECE_HUE.hasOwnProperty(name) ? PIECE_HUE[name] : 3;
      animateTo(PALETTE[idx], 900);
    });
    // …and stopping resumes the ambient cycle (or brand under reduced motion).
    stage.addEventListener("baton:stop", function () {
      locked = false;
      animateTo(reduce ? BRAND : PALETTE[i], 1400);
    });
  }

  // Ambient cycle only when motion is allowed; otherwise the hero stays brand
  // orange until the user plays a taste (a discrete, user-initiated recolor).
  if (!reduce) {
    animateTo(PALETTE[i], 2400);
    run();
    document.addEventListener("visibilitychange", function () {
      document.hidden ? halt() : run();
    });
  }
})();
