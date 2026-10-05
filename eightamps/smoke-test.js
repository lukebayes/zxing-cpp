#!/usr/bin/env node
// Smoke test for the built WASM reader. No npm dependencies.
//
// Loads zxing_reader.{js,wasm} the way eightamps/bom does (the build targets
// web and worker, so the module gets its wasm bytes through `wasmBinary`
// instead of fetching them) and decodes a Digi-Key Data Matrix label.
// Exit 1 on any miss.
//
// Usage: node eightamps/smoke-test.js [DIST_DIR]   (default: eightamps/dist)
'use strict';

const fs = require('fs');
const path = require('path');

const dist = path.resolve(process.argv[2] || path.join(__dirname, 'dist'));
const fixture = path.join(__dirname, 'fixtures', 'digikey_label_datamatrix.png');

// What the fixture encodes: an ISO/IEC 15434 Digi-Key label (RS and GS separators, EOT).
// Copied from eightamps/bom test/zxing_wasm_test.js.
const expectedPayload = '[)>\x1e06\x1dPDK-5000-ND\x1d1PMPN-5000\x1d1K12345678\x1d10K9876543' +
  '\x1d11K1\x1d4LUS\x1dQ25\x1d11ZPICK\x1d12Z1234567\x1d13Z999999\x1d20Z0000000000\x1e\x04';

// 1x1 white PNG: must decode to nothing.
const blankPng = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4//8/AwAI/AL+XJ/P2QAAAABJRU5ErkJggg==', 'base64');

function fail(message) {
  console.error(`smoke test FAILED: ${message}`);
  process.exit(1);
}

function read(zxing, png, format) {
  const ptr = zxing._malloc(png.length);
  zxing.HEAPU8.set(png, ptr);
  try {
    const results = zxing.readBarcodesFromImage(ptr, png.length, true, format, 1);
    const out = [];
    for (let i = 0; i < results.size(); i++) {
      const r = results.get(i);
      out.push({format: r.format, error: r.error, bytes: Buffer.from(r.bytes)});
    }
    return out;
  } finally {
    zxing._free(ptr);
  }
}

async function main() {
  const createModule = require(path.join(dist, 'zxing_reader.js'));
  const zxing = await createModule({wasmBinary: fs.readFileSync(path.join(dist, 'zxing_reader.wasm'))});

  const results = read(zxing, fs.readFileSync(fixture), 'DataMatrix');
  if (results.length !== 1) fail(`expected 1 result for the Digi-Key fixture, got ${results.length}`);
  if (results[0].format !== 'Data Matrix') fail(`format is ${JSON.stringify(results[0].format)}, expected "Data Matrix"`);
  if (results[0].error !== '') fail(`decoder error: ${results[0].error}`);
  const payload = results[0].bytes.toString('latin1');
  if (payload !== expectedPayload) fail(`payload mismatch: ${JSON.stringify(payload)}`);

  const blank = read(zxing, blankPng, 'DataMatrix');
  if (blank.length !== 0) fail(`expected no result for a blank image, got ${blank.length}`);

  console.log(`smoke test passed: decoded the Digi-Key Data Matrix fixture (${payload.length} bytes) with ${dist}/zxing_reader.wasm`);
}

main().catch((err) => fail(err && err.stack ? err.stack : String(err)));
