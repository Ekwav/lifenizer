#!/usr/bin/env node
// Builds dist/lifenizer-history-sync-{chromium,firefox}.zip from the sources.
// One manifest serves both browsers; the zips only differ in nothing but name
// so they can be uploaded to the respective stores. Requires the `zip` CLI.
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const dist = path.join(root, 'dist');
fs.mkdirSync(dist, { recursive: true });
for (const target of ['chromium', 'firefox']) {
  const out = path.join(dist, `lifenizer-history-sync-${target}.zip`);
  fs.rmSync(out, { force: true });
  execFileSync('zip', ['-r', '-q', out, 'manifest.json', 'icons', 'src', 'popup', 'options', 'pair', 'vendor'], { cwd: root });
  console.log('wrote', out);
}
