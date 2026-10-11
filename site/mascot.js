// Bupsy's mascot for the web: the same drawing the Mac app uses (BotFace.swift) and the design
// system ships (mascot.js), without React. Any element with data-bot="shape" becomes a live face:
//   <span data-bot="cat" data-mood="working" data-color="3" data-size="64"></span>
// Moods: idle, working, needs, done, sleeping, error. Colours: 1 to 8, the app's bot colours.
// Faces that are awake look at your pointer, or at the field you just focused.
(function () {
  var MOODS = ['idle', 'working', 'needs', 'done', 'sleeping', 'error'];
  var SHAPES = ['bup', 'blob', 'pill', 'cat', 'bunny', 'bear', 'ghost', 'horns'];
  var INK = '#141414', TONGUE = '#ff8fab';
  var seq = 0;

  function attrs(o) {
    var s = '';
    for (var k in o) if (o[k] != null && o[k] !== false) s += ' ' + k + '="' + o[k] + '"';
    return s;
  }
  function el(tag, o, kids) { return '<' + tag + attrs(o) + (kids == null ? '/>' : '>' + kids + '</' + tag + '>'); }
  function line(d, w, extra) {
    var o = { d: d, fill: 'none', stroke: 'var(--bm-dark)', 'stroke-width': w || 3.4, 'stroke-linecap': 'round', 'stroke-linejoin': 'round' };
    for (var k in extra || {}) o[k] = extra[k];
    return el('path', o);
  }
  function star(cx, cy, s) {
    var k = s * 0.2;
    return 'M' + cx + ' ' + (cy - s) + 'Q' + (cx + k) + ' ' + (cy - k) + ' ' + (cx + s) + ' ' + cy + 'Q' + (cx + k) + ' ' + (cy + k) + ' ' + cx + ' ' + (cy + s) +
      'Q' + (cx - k) + ' ' + (cy + k) + ' ' + (cx - s) + ' ' + cy + 'Q' + (cx - k) + ' ' + (cy - k) + ' ' + cx + ' ' + (cy - s) + 'Z';
  }
  function spiral(cx, cy) {
    var d = 'M' + cx + ' ' + cy, x = cx, i, r;
    for (i = 1; i <= 7; i++) { r = +(i * 1.2).toFixed(2); x = +(x + (i % 2 ? 1 : -1) * 2 * r).toFixed(2); d += 'A' + r + ' ' + r + ' 0 0 1 ' + x + ' ' + cy; }
    return d;
  }
  function openEye(cx, cy, lx, ly) {
    return el('g', {}, el('ellipse', { cx: cx, cy: cy, rx: 11.5, ry: 13.5, fill: '#ffffff' }) +
      el('g', { 'class': 'bm-look' }, el('g', { 'class': 'bm-pupil' },
        el('circle', { cx: cx + lx, cy: cy + ly, r: 6.4, fill: INK }) +
        el('circle', { cx: cx + lx + 2.3, cy: cy + ly - 2.6, r: 2.2, fill: '#ffffff' }))));
  }

  function svg(o) {
    o = o || {};
    var mood = MOODS.indexOf(o.mood) >= 0 ? o.mood : 'idle';
    var shape = SHAPES.indexOf(o.shape) >= 0 ? o.shape : 'bup';
    var size = o.size || 120, mini = size < 56;
    var gid = 'bm' + (++seq);
    var eyes, brows = '', mouth = '', arms, extras = '', antenna, bulb;

    if (mood === 'done') eyes = line('M35 66Q46 54 57 66', 4.2, { stroke: INK }) + line('M63 66Q74 54 85 66', 4.2, { stroke: INK });
    else if (mood === 'sleeping') eyes = line('M36 63Q46 70 56 63', 3.8, { stroke: INK }) + line('M64 63Q74 70 84 63', 3.8, { stroke: INK });
    else if (mood === 'error') eyes = [46, 74].map(function (cx) {
      return el('circle', { cx: cx, cy: 63, r: 12, fill: '#ffffff' }) +
        el('path', { 'class': 'bm-spin', d: spiral(cx - 0.6, 63), fill: 'none', stroke: INK, 'stroke-width': 2.2, 'stroke-linecap': 'round' });
    }).join('');
    else {
      var look = mood === 'working' ? [3.6, 3.4] : mood === 'needs' ? [0, -2.2] : [1.2, 1.4];
      eyes = el('g', { 'class': mood === 'idle' ? 'bm-blink' : null }, openEye(46, 63, look[0], look[1]) + openEye(74, 63, look[0], look[1]));
    }
    if (mood === 'working') brows = line('M35 45L54 50') + line('M85 45L66 50');
    if (mood === 'needs') brows = el('g', { 'class': 'bm-brows' }, line('M35 44Q44 37 54 42') + line('M66 42Q76 37 85 44'));

    var M = 'var(--bm-mouth)';
    if (mood === 'idle') mouth = el('path', { d: 'M53 84Q60 90.5 67 84', fill: 'none', stroke: M, 'stroke-width': 3.6, 'stroke-linecap': 'round' });
    if (mood === 'working') mouth = el('path', { d: 'M53 86L67 85', fill: 'none', stroke: M, 'stroke-width': 3.6, 'stroke-linecap': 'round' }) + el('ellipse', { cx: 64.5, cy: 89, rx: 3.6, ry: 3.2, fill: TONGUE });
    if (mood === 'needs') mouth = el('ellipse', { cx: 60, cy: 87, rx: 4.8, ry: 6, fill: M });
    if (mood === 'done') mouth = el('path', { d: 'M48 81Q60 100 72 81Z', fill: M }) + el('ellipse', { cx: 60, cy: 89.5, rx: 5.5, ry: 3.2, fill: TONGUE });
    if (mood === 'sleeping') mouth = el('ellipse', { cx: 60, cy: 86, rx: 3.2, ry: 2.6, fill: M });
    if (mood === 'error') mouth = el('path', { d: 'M48 87L52 83L56 87L60 83L64 87L68 83L72 87', fill: 'none', stroke: M, 'stroke-width': 3.2, 'stroke-linecap': 'round', 'stroke-linejoin': 'round' });

    var tuck = shape === 'pill' ? 7 : 0;
    function arm(x, y, rot, cls) {
      x = x < 60 ? x + tuck : x - tuck;
      return el('g', { transform: 'rotate(' + rot + ' ' + (x + 6.5) + ' ' + (y + 20) + ')' }, el('rect', { 'class': cls, x: x, y: y, width: 13, height: 26, rx: 6.5, fill: 'var(--bm-body)' }));
    }
    if (mood === 'needs') arms = arm(10, 70, 28) + arm(97, 30, 18, 'bm-wave');
    else if (mood === 'done') arms = arm(9, 33, -22) + arm(98, 33, 22);
    else arms = arm(10, 70, 28) + arm(97, 70, -28);

    if (mood === 'sleeping') { antenna = 'M60 31Q63 19 76 21'; bulb = [78, 22]; }
    else { antenna = 'M60 31Q57 20 65 13'; bulb = [66, 12]; }

    if (mood === 'working') extras += el('path', { 'class': 'bm-sweat', d: 'M101 41q5.5 7.5 0 11q-5.5-3.5 0-11Z', fill: '#8fd3ff' });
    if (mood === 'needs') extras += el('g', { 'class': 'bm-alert', stroke: 'var(--bm-body)', 'stroke-width': 3, 'stroke-linecap': 'round' },
      el('path', { d: 'M94 12l-3-6' }) + el('path', { d: 'M104 9l1-7' }) + el('path', { d: 'M113 14l5-5' }));
    if (mood === 'done') [[14, 46, 7], [106, 14, 6.5], [112, 60, 5], [24, 14, 4.5]].forEach(function (s, i) {
      extras += el('path', { 'class': 'bm-spark', style: 'animation-delay:' + (i * 0.25) + 's', d: star(s[0], s[1], s[2]), fill: '#f7b928' });
    });
    if (mood === 'sleeping') {
      [[86, 14, 1], [97, 6, 0.75], [106, 0, 0.55]].forEach(function (z, i) {
        extras += el('path', { 'class': 'bm-z', style: 'animation-delay:' + (i * 0.9) + 's', d: 'M' + z[0] + ' ' + (z[1] + 4) + 'h' + 7 * z[2] + 'l-' + 7 * z[2] + ' ' + 8 * z[2] + 'h' + 7 * z[2], fill: 'none', stroke: 'var(--muted)', 'stroke-width': 2.2, 'stroke-linecap': 'round', 'stroke-linejoin': 'round' });
      });
      extras += el('circle', { 'class': 'bm-bubble', cx: 69, cy: 83, r: 5, fill: '#cfeeff', 'fill-opacity': 0.75, stroke: '#ffffff', 'stroke-width': 1.2 });
    }
    var orbit = (mood === 'error' && !mini) ? el('g', { 'class': 'bm-orbit' }, [0, 120, 240].map(function (a) {
      var r = a * Math.PI / 180; return el('path', { d: star(+(60 + 24 * Math.cos(r)).toFixed(1), +(20 + 24 * Math.sin(r)).toFixed(1), 5), fill: '#f7b928' });
    }).join('')) : '';

    var B = 'var(--bm-body)', D = 'var(--bm-dark)', Lt = 'var(--bm-light)', fill = 'url(#' + gid + ')';
    var behind = '', body;
    if (shape === 'blob') body = el('ellipse', { cx: 60, cy: 70, rx: 44, ry: 41, fill: fill });
    else if (shape === 'pill') body = el('rect', { x: 25, y: 22, width: 70, height: 88, rx: 35, fill: fill });
    else if (shape === 'ghost') body = el('path', { d: 'M18 68A42 40 0 0 1 102 68V104q-7 9 -14 0t-14 0t-14 0t-14 0t-14 0t-14 0Z', fill: fill });
    else body = el('rect', { x: 18, y: 30, width: 84, height: 79, rx: 31, fill: fill });
    if (shape === 'cat') behind =
      el('path', { d: 'M23 50L29 14L55 33Z', fill: B, stroke: B, 'stroke-width': 7, 'stroke-linejoin': 'round' }) +
      el('path', { d: 'M97 50L91 14L65 33Z', fill: B, stroke: B, 'stroke-width': 7, 'stroke-linejoin': 'round' }) +
      el('path', { d: 'M31 36L33 23L43 31Z', fill: Lt, stroke: Lt, 'stroke-width': 3, 'stroke-linejoin': 'round' }) +
      el('path', { d: 'M89 36L87 23L77 31Z', fill: Lt, stroke: Lt, 'stroke-width': 3, 'stroke-linejoin': 'round' });
    if (shape === 'bunny') behind =
      el('ellipse', { cx: 40, cy: 20, rx: 10, ry: 24, fill: B, transform: 'rotate(-12 40 20)' }) +
      el('ellipse', { cx: 80, cy: 20, rx: 10, ry: 24, fill: B, transform: 'rotate(12 80 20)' }) +
      el('ellipse', { cx: 40, cy: 20, rx: 4.5, ry: 16, fill: Lt, transform: 'rotate(-12 40 20)' }) +
      el('ellipse', { cx: 80, cy: 20, rx: 4.5, ry: 16, fill: Lt, transform: 'rotate(12 80 20)' });
    if (shape === 'bear') behind =
      el('circle', { cx: 28, cy: 36, r: 14, fill: B }) + el('circle', { cx: 92, cy: 36, r: 14, fill: B }) +
      el('circle', { cx: 28, cy: 36, r: 6.5, fill: D, opacity: 0.35 }) + el('circle', { cx: 92, cy: 36, r: 6.5, fill: D, opacity: 0.35 });
    if (shape === 'horns') behind =
      el('path', { d: 'M30 42Q19 22 31 12Q33 28 46 34Z', fill: D }) +
      el('path', { d: 'M90 42Q101 22 89 12Q87 28 74 34Z', fill: D });

    var feet = shape === 'ghost' ? '' : el('ellipse', { cx: 45, cy: 107, rx: 9.5, ry: 5.8, fill: D }) + el('ellipse', { cx: 75, cy: 107, rx: 9.5, ry: 5.8, fill: D });
    var face = el('g', { 'class': 'bm-face' },
      el('ellipse', { cx: 31, cy: 80, rx: 6, ry: 3.6, fill: D, opacity: 0.22 }) +
      el('ellipse', { cx: 89, cy: 80, rx: 6, ry: 3.6, fill: D, opacity: 0.22 }) + eyes + brows + mouth);
    var cls = ['bm', 'bm-' + mood, mini ? 'bm-mini' : '', o.still ? 'bm-still' : '',
      (!o.still && (mood === 'idle' || mood === 'needs' || mood === 'done')) ? 'bm-tracks' : ''].join(' ').replace(/\s+/g, ' ').trim();
    var color = o.color ? 'var(--bot-' + o.color + ')' : 'var(--bot-1)';

    return '<svg class="' + cls + '" viewBox="0 0 120 120" width="' + size + '" height="' + size + '" aria-hidden="true" style="--bm-body:' + color + '">' +
      el('defs', {}, el('radialGradient', { id: gid, cx: '42%', cy: '34%', r: '72%' },
        el('stop', { offset: 0, style: 'stop-color:var(--bm-light)' }) + el('stop', { offset: 1, style: 'stop-color:var(--bm-body)' }))) +
      (mini || o.noShadow ? '' : el('ellipse', { 'class': 'bm-shadow', cx: 60, cy: 113, rx: 28, ry: 3.6 })) + orbit +
      el('g', { 'class': 'bm-fig' }, behind + feet + arms +
        el('path', { d: antenna, fill: 'none', stroke: D, 'stroke-width': 3.2, 'stroke-linecap': 'round' }) +
        el('circle', { 'class': 'bm-bulb', cx: bulb[0], cy: bulb[1], r: 5.6 }) + body + face) +
      (mini ? '' : el('g', { 'class': 'bm-extra' }, extras)) + '</svg>';
  }

  function render(node) {
    var d = node.dataset;
    node.innerHTML = svg({ shape: d.bot, mood: d.mood, color: d.color, size: +d.size || 64, still: 'still' in d, noShadow: 'noShadow' in d });
  }
  function setMood(node, mood) { if (node.dataset.mood !== mood) { node.dataset.mood = mood; render(node); } }

  // One pointer listener and one frame of work per move, for every awake face on the page.
  var reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)');
  var tx = null, ty = null, queued = false;
  function apply() {
    queued = false;
    if (tx == null || (reduce && reduce.matches)) return;
    var list = document.querySelectorAll('svg.bm-tracks');
    for (var i = 0; i < list.length; i++) {
      var r = list[i].getBoundingClientRect();
      if (!r.width || r.bottom < 0 || r.top > innerHeight) continue;
      var dx = tx - (r.left + r.width / 2), dy = ty - (r.top + r.height * 0.52);
      var dist = Math.sqrt(dx * dx + dy * dy) || 1, k = Math.min(1, dist / 240);
      list[i].style.setProperty('--bm-lx', (dx / dist * 3.4 * k).toFixed(2) + 'px');
      list[i].style.setProperty('--bm-ly', (dy / dist * 2.6 * k).toFixed(2) + 'px');
    }
  }
  function aim(x, y) { tx = x; ty = y; if (!queued) { queued = true; requestAnimationFrame(apply); } }
  document.addEventListener('pointermove', function (e) { aim(e.clientX, e.clientY); }, { passive: true });
  document.addEventListener('focusin', function (e) {
    var t = e.target; if (!t || !/INPUT|TEXTAREA/.test(t.tagName)) return;
    var r = t.getBoundingClientRect(); aim(r.left + Math.min(r.width, 160), r.top + r.height / 2);
  });

  window.Bupsy = { svg: svg, render: render, setMood: setMood, mountAll: function (root) {
    (root || document).querySelectorAll('[data-bot]').forEach(render);
  } };
})();
