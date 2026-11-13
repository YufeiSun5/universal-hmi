// getRandomValues is available on private HTTP origins; randomUUID is not.
// Collaboration window and operation IDs still use cryptographic randomness.
export function randomID(cryptoSource = globalThis.crypto) {
  return Array.from(cryptoSource.getRandomValues(new Uint8Array(16)),
    value => value.toString(16).padStart(2, '0')).join('');
}
