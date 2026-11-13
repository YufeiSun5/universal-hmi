import test from 'node:test';
import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
import { randomID } from './identity.mjs';

test('collaboration IDs work without secure-context randomUUID on LAN HTTP', () => {
  const insecureContext = {getRandomValues: data => webcrypto.getRandomValues(data)};
  const ids = new Set(Array.from({length: 100}, () => randomID(insecureContext)));
  assert.equal(ids.size, 100);
  for (const id of ids) assert.match(id, /^[0-9a-f]{32}$/);
});
