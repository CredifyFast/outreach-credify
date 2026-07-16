// Trivial smoke test so CI has something real to run.
// Replace/extend this as real domain modules land under src/.
const { test } = require('node:test');
const assert = require('node:assert');

test('package.json metadata is intact', () => {
  const pkg = require('../package.json');
  assert.strictEqual(pkg.name, 'outreach-credify');
  assert.ok(pkg.private === true, 'package must stay private (proprietary, HIPAA)');
});
