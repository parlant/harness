const ballroom = document.querySelector('.ballroom');
if (ballroom && 'IntersectionObserver' in window && 'ResizeObserver' in window) stageDance(ballroom);

function stageDance(stage) {
  const motion = matchMedia('(prefers-reduced-motion: no-preference)');
  const turn = 2 * Math.PI;
  // Offset the wing visits; give each figure a different walking tempo.
  const phases = [0.24, 0.84, 0.13, 0.33, 0.53, 0.73, 0.93];
  const tempos = [8.8, 10.2, 9.5, 10.7, 11.3, 8.3, 9.9];
  const puppets = [...stage.querySelectorAll('.ballroom-puppet')].map((el, i) => ({
    el, i, phase: phases[i], tempo: tempos[i],
    portrait: el.querySelector('.puppet-portrait'),
    facing: el.dataset.facing === 'left' ? -1 : 1,
  }));
  let visible = false, frame = null, previous = null, time = 0;
  const clamp = (x, min, max) => Math.max(min, Math.min(x, max));
  const ease = (a, b, t) => {
    const x = clamp((t - a) / (b - a), 0, 1);
    return x * x * (3 - 2 * x);
  };

  function measure() {
    const width = stage.clientWidth;
    const height = stage.clientHeight;
    for (const p of puppets) {
      const w = p.el.offsetWidth;
      p.h = p.el.offsetHeight;
      p.mark = p.el.offsetLeft;
      p.angle = parseFloat(getComputedStyle(p.el).getPropertyValue('--angle'));
      p.travel = Math.min(w * (0.46 + p.i % 3 * 0.12), width * 0.1);
      const wing = p.mark < width / 2 ? -1 : 1;
      // Allow for up to nine degrees of tilt, including the rod below the cutout.
      const margin = Math.max(w / 2 + p.h * 0.16, height * 0.16) + 16;
      p.exit = wing < 0 ? -margin : width + margin;
    }
    if (stage.dataset.dance) draw();
  }

  function position(p, at) {
    const phrase = (at / 25 + p.phase) % 1;
    const visit = ease(0.71, 0.84, phrase) * (1 - ease(0.88, 0.995, phrase));
    const promenade = p.travel * Math.sin(turn * (at / p.tempo + p.phase));
    return (1 - visit) * promenade + visit * (p.exit - p.mark);
  }

  function draw() {
    for (const p of puppets) {
      if (!p.h) continue;
      const x = position(p, time);
      const speed = (position(p, time + 0.02) - x) / 0.02;
      // Keep the pose at a standstill instead of flickering around zero speed.
      if (Math.abs(speed) > 4) {
        const flip = Math.sign(speed) === p.facing ? 1 : -1;
        const mirror = `scaleX(${flip})`;
        if (p.portrait.style.transform !== mirror) p.portrait.style.transform = mirror;
      }
      const stride = turn * (time / (1.24 + p.i * 0.05) + p.phase);
      const walking = Math.min(Math.abs(speed) / 50, 1);
      const lift = Math.min(p.h * 0.024, 6) * walking * Math.sin(stride) ** 2;
      const rock = walking * 2 * Math.sin(stride);
      const lean = 3 * clamp(speed / 60, -1, 1);
      // The portrait turns around the rod. The rod and cutout move as one rigid piece.
      p.el.style.transform = `translate(calc(-50% + ${x}px), ${-lift}px) rotate(${p.angle + lean + rock}deg)`;
    }
  }

  function tick(now) {
    if (previous !== null) time += (now - previous) / 1000;
    previous = now;
    draw();
    frame = requestAnimationFrame(tick);
  }

  function update() {
    if (motion.matches && visible && !document.hidden) {
      if (frame !== null) return;
      draw();
      stage.dataset.dance = 'running';
      frame = requestAnimationFrame(tick);
      return;
    }
    if (frame !== null) cancelAnimationFrame(frame);
    frame = previous = null;
    if (!motion.matches) {
      delete stage.dataset.dance;
      for (const p of puppets) {
        p.el.style.removeProperty('transform');
        p.portrait.style.removeProperty('transform');
      }
      time = 0;
    } else if (stage.dataset.dance) {
      stage.dataset.dance = 'paused';
    }
  }

  measure();
  new ResizeObserver(measure).observe(stage);
  new IntersectionObserver(([entry]) => {
    visible = entry.isIntersecting && entry.intersectionRatio >= 0.2;
    update();
  }, { threshold: 0.2 }).observe(stage);
  document.addEventListener('visibilitychange', update);
  motion.addEventListener('change', update);
}
