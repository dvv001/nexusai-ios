/* ============================================================================
   Layer 4: Web Audio Sound Engine (Nexus.audio)
   UI blips are synthesized one-shots; pipeline runs are scored by a layered,
   generative D-minor "legion battle" war score (drums / bass / strings /
   brass) whose intensity follows live run progress. No audio assets.
   ============================================================================ */
(function (global) {
  'use strict';

  const Nexus = (global.Nexus = global.Nexus || {});
  const { KEYS } = Nexus.CONST;
  const { ls } = Nexus.store;

  const audioState = {
    enabled: ls.getRaw(KEYS.SFX) !== '0',
    ctx: null,
    lastStreamTickMs: 0,
    lastSpiderStepMs: 0
  };

  function ensureContext() {
    if (!audioState.enabled) return null;
    const AudioCtx = global.AudioContext || global.webkitAudioContext;
    if (!AudioCtx) return null;
    if (!audioState.ctx) {
      try { audioState.ctx = new AudioCtx(); } catch (_) { return null; }
    }
    if (audioState.ctx && audioState.ctx.state === 'suspended') {
      try { audioState.ctx.resume(); } catch (_) {}
    }
    return audioState.ctx;
  }

  function playTone(freq, endFreq, durSec, type = 'sine', gainVal = 0.08, delaySec = 0) {
    const ac = ensureContext();
    if (!ac) return;
    try {
      const t0 = ac.currentTime + delaySec;
      const osc = ac.createOscillator();
      const gain = ac.createGain();
      osc.type = type;
      osc.frequency.setValueAtTime(freq, t0);
      if (endFreq && endFreq !== freq) {
        osc.frequency.exponentialRampToValueAtTime(Math.max(20, endFreq), t0 + durSec);
      }
      gain.gain.setValueAtTime(0.0001, t0);
      gain.gain.linearRampToValueAtTime(gainVal, t0 + Math.min(0.015, durSec * 0.25));
      gain.gain.exponentialRampToValueAtTime(0.0001, t0 + durSec);
      osc.connect(gain);
      gain.connect(ac.destination);
      osc.start(t0);
      osc.stop(t0 + durSec + 0.015);
    } catch (_) {}
  }

  /* ==========================================================================
     War Score — layered generative battle music for pipeline runs.
     D minor, 112 BPM, 4-bar loop (Dm – Bb – F – C):
       Layer A 战鼓  taiko drums, galloping pattern — from run start
       Layer B 低音  pulsing bass ostinato (root/fifth/octave) — from run start
       Layer C 弦乐  staccato string ostinato — fades in with progress
       Layer D 铜管  brass chord stabs on phrase boundaries — late phase
     Intensity is derived from live run state (agents done / total + elapsed).
     ========================================================================== */
  const SCORE_BPM = 112;
  const STEP_DUR = 60 / SCORE_BPM / 2; // one 8th note
  const SCORE_CHORDS = [
    { bass: 73.42, strings: [293.66, 349.23, 440.0], brass: [146.83, 174.61, 220.0] }, // Dm
    { bass: 58.27, strings: [233.08, 293.66, 349.23], brass: [116.54, 146.83, 174.61] }, // Bb
    { bass: 87.31, strings: [349.23, 440.0, 523.25], brass: [174.61, 220.0, 261.63] }, // F
    { bass: 65.41, strings: [329.63, 392.0, 523.25], brass: [130.81, 164.81, 196.0] } // C
  ];
  const KICK_STEPS = new Set([2, 3, 5, 6]); // gallop: 0(deep) . K K . K K .

  const score = {
    active: false,
    ctx: null,
    master: null,
    drumBus: null,
    noiseBuf: null,
    timer: 0,
    step: 0,
    nextTime: 0,
    startedAt: 0
  };

  function makeNoiseBuffer(ac) {
    const len = Math.max(1, Math.floor(ac.sampleRate * 1));
    const buf = ac.createBuffer(1, len, ac.sampleRate);
    const data = buf.getChannelData(0);
    for (let i = 0; i < len; i++) data[i] = Math.random() * 2 - 1;
    return buf;
  }

  function scorePhase(t) {
    let ratio = 0;
    let done = 0;
    try {
      const st = Nexus.state;
      if (st && Array.isArray(st.agents)) {
        const en = st.agents.filter((a) => a && a.enabled !== false);
        done = en.filter((a) => a.status === 'done').length;
        ratio = en.length ? done / en.length : 0;
      }
    } catch (_) {}
    const elapsed = t - score.startedAt;
    if (ratio >= 0.55 || elapsed >= 75) return 2;
    if (done >= 1 || ratio >= 0.3 || elapsed >= 20) return 1;
    return 0;
  }

  function drumHit(t, deep, dest) {
    const ac = score.ctx;
    if (!ac) return;
    const out = dest || score.drumBus;
    if (!out) return;
    try {
      const osc = ac.createOscillator();
      const g = ac.createGain();
      osc.type = 'sine';
      osc.frequency.setValueAtTime(deep ? 112 : 132, t);
      osc.frequency.exponentialRampToValueAtTime(deep ? 33 : 43, t + (deep ? 0.34 : 0.22));
      g.gain.setValueAtTime(deep ? 0.85 : 0.6, t);
      g.gain.exponentialRampToValueAtTime(0.001, t + (deep ? 0.44 : 0.3));
      osc.connect(g);
      g.connect(out);
      osc.start(t);
      osc.stop(t + (deep ? 0.48 : 0.34));

      if (score.noiseBuf) {
        const src = ac.createBufferSource();
        src.buffer = score.noiseBuf;
        const nf = ac.createBiquadFilter();
        nf.type = 'lowpass';
        nf.frequency.value = deep ? 520 : 760;
        const ng = ac.createGain();
        ng.gain.setValueAtTime(deep ? 0.3 : 0.2, t);
        ng.gain.exponentialRampToValueAtTime(0.001, t + 0.07);
        src.connect(nf);
        nf.connect(ng);
        ng.connect(out);
        src.start(t);
        src.stop(t + 0.09);
      }
    } catch (_) {}
  }

  function tokHit(t) {
    const ac = score.ctx;
    if (!ac || !score.master) return;
    try {
      const osc = ac.createOscillator();
      const g = ac.createGain();
      osc.type = 'square';
      osc.frequency.setValueAtTime(640, t);
      osc.frequency.exponentialRampToValueAtTime(470, t + 0.045);
      g.gain.setValueAtTime(0.055, t);
      g.gain.exponentialRampToValueAtTime(0.001, t + 0.05);
      osc.connect(g);
      g.connect(score.master);
      osc.start(t);
      osc.stop(t + 0.06);
    } catch (_) {}
  }

  function bassNote(t, freq) {
    const ac = score.ctx;
    if (!ac || !score.master) return;
    try {
      const osc = ac.createOscillator();
      const flt = ac.createBiquadFilter();
      const g = ac.createGain();
      osc.type = 'sawtooth';
      osc.frequency.setValueAtTime(freq, t);
      flt.type = 'lowpass';
      flt.frequency.value = 280;
      g.gain.setValueAtTime(0.0001, t);
      g.gain.linearRampToValueAtTime(0.22, t + 0.012);
      g.gain.exponentialRampToValueAtTime(0.001, t + STEP_DUR * 0.92);
      osc.connect(flt);
      flt.connect(g);
      g.connect(score.master);
      osc.start(t);
      osc.stop(t + STEP_DUR);
    } catch (_) {}
  }

  function stringNote(t, freq) {
    const ac = score.ctx;
    if (!ac || !score.master) return;
    try {
      const osc = ac.createOscillator();
      const flt = ac.createBiquadFilter();
      const g = ac.createGain();
      osc.type = 'sawtooth';
      osc.frequency.setValueAtTime(freq, t);
      flt.type = 'lowpass';
      flt.frequency.value = 1350;
      g.gain.setValueAtTime(0.0001, t);
      g.gain.linearRampToValueAtTime(0.13, t + 0.01);
      g.gain.exponentialRampToValueAtTime(0.001, t + STEP_DUR * 0.9);
      osc.connect(flt);
      flt.connect(g);
      g.connect(score.master);
      osc.start(t);
      osc.stop(t + STEP_DUR);
    } catch (_) {}
  }

  function brassStab(t, freqs) {
    const ac = score.ctx;
    if (!ac || !score.master) return;
    try {
      freqs.forEach((freq) => {
        [-6, 5].forEach((cents) => {
          const osc = ac.createOscillator();
          const flt = ac.createBiquadFilter();
          const g = ac.createGain();
          osc.type = 'sawtooth';
          osc.frequency.setValueAtTime(freq, t);
          if (osc.detune) osc.detune.setValueAtTime(cents, t);
          flt.type = 'lowpass';
          flt.frequency.setValueAtTime(480, t);
          flt.frequency.linearRampToValueAtTime(1650, t + 0.22);
          flt.frequency.linearRampToValueAtTime(700, t + STEP_DUR * 3.2);
          g.gain.setValueAtTime(0.0001, t);
          g.gain.linearRampToValueAtTime(0.052, t + 0.075);
          g.gain.setValueAtTime(0.052, t + STEP_DUR * 1.6);
          g.gain.exponentialRampToValueAtTime(0.001, t + STEP_DUR * 3.4);
          osc.connect(flt);
          flt.connect(g);
          g.connect(score.master);
          osc.start(t);
          osc.stop(t + STEP_DUR * 3.5);
        });
      });
    } catch (_) {}
  }

  function scheduleScoreStep(step, t) {
    const bar = Math.floor(step / 8) % SCORE_CHORDS.length;
    const s = step % 8;
    const chord = SCORE_CHORDS[bar];
    const phase = scorePhase(t);

    // Layer A — war drums (gallop), present from the start.
    if (s === 0) drumHit(t, true);
    else if (KICK_STEPS.has(s)) drumHit(t, false);
    if (bar === SCORE_CHORDS.length - 1 && s === 7) drumHit(t + STEP_DUR * 0.5, false); // phrase fill
    if (phase >= 1 && s % 2 === 1) tokHit(t);

    // Layer B — pulsing bass ostinato (root, with fifth/octave lifts).
    const bassFreq = s === 3 ? chord.bass * 1.5 : (s === 6 ? chord.bass * 2 : chord.bass);
    bassNote(t, bassFreq);

    // Layer C — rhythmic string ostinato once the run is underway.
    if (phase >= 1) {
      const idx = [0, 1, 2, 1][s % 4];
      stringNote(t, chord.strings[idx]);
    }

    // Layer D — brass stabs on phrase boundaries in the late phase.
    if (phase >= 2 && s === 0 && bar % 2 === 0) {
      brassStab(t, chord.brass);
    }
  }

  function scoreTick() {
    if (!score.active || !score.ctx) return;
    const ac = score.ctx;
    try {
      while (score.nextTime < ac.currentTime + 0.3) {
        scheduleScoreStep(score.step, score.nextTime);
        score.nextTime += STEP_DUR;
        score.step++;
      }
    } catch (_) {}
  }

  function scoreStart() {
    if (!audioState.enabled) return;
    const ac = ensureContext();
    if (!ac) return;
    scoreStop(0.03);
    try {
      score.ctx = ac;
      score.master = ac.createGain();
      score.master.gain.value = 0.3;
      score.master.connect(ac.destination);
      score.drumBus = ac.createGain();
      score.drumBus.gain.value = 0.8;
      score.drumBus.connect(score.master);
      score.noiseBuf = makeNoiseBuffer(ac);
      score.step = 0;
      score.startedAt = ac.currentTime + 0.06;
      score.nextTime = score.startedAt;
      score.active = true;
      score.timer = setInterval(scoreTick, 90);
      scoreTick();
    } catch (_) {
      score.active = false;
    }
  }

  function scoreStop(fadeSec) {
    if (score.timer) {
      clearInterval(score.timer);
      score.timer = 0;
    }
    if (!score.active) return;
    score.active = false;
    const ac = score.ctx;
    const master = score.master;
    score.master = null;
    score.drumBus = null;
    if (ac && master) {
      try {
        const fade = typeof fadeSec === 'number' ? fadeSec : 0.15;
        const t = ac.currentTime;
        master.gain.cancelScheduledValues(t);
        master.gain.setValueAtTime(master.gain.value, t);
        master.gain.linearRampToValueAtTime(0.0001, t + fade);
        setTimeout(() => { try { master.disconnect(); } catch (_) {} }, (fade + 0.2) * 1000);
      } catch (_) {}
    }
  }

  function swellTone(ac, dest, t, freq, type, peak) {
    const osc = ac.createOscillator();
    const g = ac.createGain();
    osc.type = type;
    osc.frequency.setValueAtTime(freq, t);
    g.gain.setValueAtTime(0.0001, t);
    g.gain.linearRampToValueAtTime(peak, t + 0.45);
    g.gain.setValueAtTime(peak, t + 1.1);
    g.gain.exponentialRampToValueAtTime(0.001, t + 2.3);
    osc.connect(g);
    g.connect(dest);
    osc.start(t);
    osc.stop(t + 2.4);
  }

  function scoreFinale(success) {
    scoreStop(0.1);
    const ac = ensureContext();
    if (!ac) return;
    try {
      const t = ac.currentTime + 0.03;
      const bus = ac.createGain();
      bus.gain.value = 0.34;
      bus.connect(ac.destination);
      drumHit(t, true, bus);
      if (success) {
        // Resolving D-major swell (D – F# – A – D) over the final drum hit.
        [146.83, 185.0, 220.0, 293.66].forEach((f) => {
          swellTone(ac, bus, t, f, 'sawtooth', 0.05);
          swellTone(ac, bus, t, f, 'triangle', 0.045);
        });
        swellTone(ac, bus, t + 0.15, 587.33, 'sine', 0.028);
      } else {
        // One low dissonant hit: D + Eb cluster through a dark lowpass.
        [73.42, 77.78, 146.83].forEach((f) => {
          const osc = ac.createOscillator();
          const flt = ac.createBiquadFilter();
          const g = ac.createGain();
          osc.type = 'sawtooth';
          osc.frequency.setValueAtTime(f, t);
          flt.type = 'lowpass';
          flt.frequency.value = 420;
          g.gain.setValueAtTime(0.0001, t);
          g.gain.linearRampToValueAtTime(0.13, t + 0.05);
          g.gain.exponentialRampToValueAtTime(0.001, t + 1.0);
          osc.connect(flt);
          flt.connect(g);
          g.connect(bus);
          osc.start(t);
          osc.stop(t + 1.05);
        });
      }
      setTimeout(() => { try { bus.disconnect(); } catch (_) {} }, 3200);
    } catch (_) {}
  }

  /* ===== SFX (public call sites preserved) ===== */
  const sfx = {
    uiClick() {
      playTone(960, 1380, 0.045, 'triangle', 0.045, 0);
    },
    missionLaunch() {
      // Run start = war score entrance (drums + bass from the first beat).
      scoreStart();
    },
    agentStart(idx) {
      const freqs = [523.25, 587.33, 659.25, 783.99, 880.0];
      const f = freqs[idx % freqs.length] || 587.33;
      playTone(f * 0.75, f, 0.09, 'triangle', 0.05, 0);
      playTone(f, f * 1.25, 0.14, 'sine', 0.055, 0.07);
    },
    streamTick() {
      const now = performance.now();
      if (now - audioState.lastStreamTickMs < 92) return;
      audioState.lastStreamTickMs = now;
      const pitch = 1750 + Math.random() * 450;
      playTone(pitch, pitch * 0.85, 0.022, 'sine', 0.024, 0);
    },
    nodeCompleteAndCompact() {
      playTone(659.25, 659.25, 0.09, 'triangle', 0.075, 0);
      playTone(987.77, 1046.5, 0.16, 'sine', 0.085, 0.07);
      playTone(420, 190, 0.12, 'sine', 0.04, 0.12);
    },
    pipelineSuccess() {
      // Run success = resolving swell finale (stops the loop first).
      scoreFinale(true);
    },
    parallelFork() {
      playTone(330, 660, 0.12, 'sawtooth', 0.05, 0);
      playTone(495, 990, 0.14, 'triangle', 0.06, 0.05);
      playTone(660, 1320, 0.16, 'sine', 0.07, 0.10);
    },
    autoHealRetry() {
      playTone(440, 330, 0.11, 'sawtooth', 0.06, 0);
      playTone(330, 660, 0.16, 'triangle', 0.075, 0.11);
    },
    errorOrAbort() {
      if (score.active) {
        // Run failure = one low dissonant hit, then silence.
        scoreFinale(false);
        return;
      }
      playTone(195, 135, 0.18, 'sawtooth', 0.085, 0);
      playTone(165, 110, 0.24, 'sawtooth', 0.085, 0.15);
    },
    scoreStop() {
      scoreStop(0.15);
    },
    spiderStep(isPrimary) {
      const topoView = document.getElementById('tabViewTopology');
      if (!topoView || topoView.classList.contains('hidden')) return;
      const now = performance.now();
      if (now - audioState.lastSpiderStepMs < 135) return;
      audioState.lastSpiderStepMs = now;
      const base = isPrimary ? 1180 : 1560;
      playTone(base, base * 0.72, 0.018, 'triangle', 0.018, 0);
    },
    spiderZap() {
      playTone(1480, 420, 0.065, 'sawtooth', 0.04, 0);
    }
  };

  function setEnabled(val) {
    audioState.enabled = Boolean(val);
    ls.setRaw(KEYS.SFX, audioState.enabled ? '1' : '0');
    if (!audioState.enabled) scoreStop(0.05);
  }

  Nexus.audio = {
    get enabled() { return audioState.enabled; },
    setEnabled,
    ensureContext,
    sfx
  };
})(window);
