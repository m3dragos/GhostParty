const fs = require('fs');
for (const f of process.argv.slice(2)) {
  let s = fs.readFileSync(f, 'utf8');
  s = s.replace(/--\[\[[\s\S]*?\]\]/g, '').replace(/--[^\n]*/g, '')
       .replace(/"(\\.|[^"\\\n])*"/g, '""').replace(/'(\\.|[^'\\\n])*'/g, "''");
  const w = s.match(/\b(function|if|for|while|end|do|then|elseif)\b/g) || [];
  let open = 0, ends = 0, ifs = 0, thens = 0, loops = 0, dos = 0;
  for (const k of w) {
    if (k === 'function') open++;
    else if (k === 'if') { open++; ifs++; }
    else if (k === 'for' || k === 'while') { open++; loops++; }
    else if (k === 'end') ends++;
    else if (k === 'then') thens++;
    else if (k === 'elseif') ifs++;
    else if (k === 'do') dos++;
  }
  const pb = (s.match(/\(/g) || []).length - (s.match(/\)/g) || []).length;
  const cb = (s.match(/\{/g) || []).length - (s.match(/\}/g) || []).length;
  const ok = open === ends && ifs === thens && loops === dos && !pb && !cb;
  console.log(f.padEnd(14), ok ? 'OK' : 'PROBLEM', 'blocks', open, 'ends', ends, 'if/then', ifs, thens, 'loop/do', loops, dos, 'paren', pb, 'brace', cb);
}
