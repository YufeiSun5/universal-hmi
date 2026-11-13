// Cell revisions belong to the server. Keep the exact in-flight operation until
// its outcome is known; a timeout must not turn a retry into a new operation.
export class CellSync {
  constructor(cells = [], revision = 0) {
    this.cells = new Map(cells.map(c => [c.address, c]));
    this.revision = revision;
    this.pending = new Map();
    this.conflicts = new Map();
    this.flight = null;
  }
  value(address) { return this.pending.get(address)?.value ?? this.cells.get(address)?.value ?? ''; }
  edit(address, value, format) {
    const old = this.cells.get(address) || { value: '', revision: 0 };
    const existing = this.pending.get(address);
    format = format ?? existing?.format ?? old.format;
    if (value === old.value && sameFormat(format,old.format) && !this.flight) this.pending.delete(address);
    else this.pending.set(address, { address, value, expected: existing?.expected ?? old.revision, ...(format===undefined?{}:{format}) });
  }
  batch(id) {
    if (this.flight) return this.flight;
    if (this.conflicts.size || !this.pending.size) return null;
    this.flight = { id, changes: [...this.pending.values()].slice(0, 1000).map(c => ({...c})) };
    return this.flight;
  }
  acknowledge(result) {
    const flight = this.flight;
    for (const sent of flight.changes) {
      const current = result.cells.find(c => c.address === sent.address)
        || this.cells.get(sent.address) || {address: sent.address, value: sent.value, revision: sent.expected};
      const known = this.cells.get(sent.address);
      if (known && known.revision > current.revision) continue;
      this.cells.set(sent.address, current);
      // A poll may see our committed batch before its HTTP receipt arrives.
      // That echo is not a conflict with our own successful save.
      this.conflicts.delete(sent.address);
      const draft = this.pending.get(sent.address);
      if (draft?.value === sent.value && sameFormat(draft?.format,sent.format)) this.pending.delete(sent.address);
      else if (draft) this.pending.set(sent.address, {...draft, expected: current.revision});
    }
    // Do not advance the polling cursor: this receipt may omit another user's
    // changes committed before our batch. Only a complete delta advances it.
    this.flight = null;
  }
  merge(result) {
    for (const cell of result.cells) {
      const previous = this.cells.get(cell.address);
      if (previous && previous.revision > cell.revision) continue;
      const draft = this.pending.get(cell.address);
      if (draft && cell.revision !== draft.expected) {
        this.conflicts.set(cell.address, {mine: draft.value, theirs: cell.value, format:cell.format, actor: cell.actor});
      }
      this.cells.set(cell.address, cell);
    }
    this.revision = Math.max(this.revision, result.revision);
  }
  rejectConflict() { this.flight = null; }
  resolve(address, keepMine) {
    const draft = this.pending.get(address);
    if (keepMine && draft) this.pending.set(address, {...draft, expected: this.cells.get(address)?.revision || 0});
    else this.pending.delete(address);
    this.conflicts.delete(address);
  }
  get dirty() { return !!(this.pending.size || this.flight); }
}
export function sameFormat(a,b){return JSON.stringify(Object.entries(a||{}).sort())===JSON.stringify(Object.entries(b||{}).sort());}
function color(v,fallback){if(!v)return fallback;const rgb=/^rgba?\((\d+),\s*(\d+),\s*(\d+)/.exec(v);if(rgb)return '#'+rgb.slice(1,4).map(n=>Math.min(255,Number(n)).toString(16).padStart(2,'0')).join('');return v;}
export function cellFormat(v={}){return {bg:color(v.bg,'#FFFFFF'),fc:color(v.fc,'#000000'),ff:v.ff||'Arial',fs:v.fs??11,bl:v.bl?1:0,it:v.it?1:0,un:v.un?1:0,cl:v.cl?1:0,ht:v.ht??0,vt:v.vt??0,tb:v.tb??0,nf:v.nf||v.ct?.fa||'General'};}
export function address(r, c) {
  let letters = '';
  for (let n = c + 1; n; n = Math.floor((n - 1) / 26)) letters = String.fromCharCode(65 + (n - 1) % 26) + letters;
  return letters + (r + 1);
}
export function coordinates(a) {
  const [, letters, row] = /^([A-Z]+)(\d+)$/.exec(a);
  return [Number(row) - 1, [...letters].reduce((n, c) => n * 26 + c.charCodeAt(0) - 64, 0) - 1];
}
export function selectionAddress(range) {
  const r0=range?.row?.[0], c0=range?.column?.[0];
  const r1=range?.row?.[1]??r0, c1=range?.column?.[1]??c0;
  if (![r0,c0,r1,c1].every(v=>Number.isInteger(v)&&v>=0)) return '';
  return `${address(Math.min(r0,r1),Math.min(c0,c1))}:${address(Math.max(r0,r1),Math.max(c0,c1))}`;
}
export function numeric(v) {
  return v === '' || (String(v).length <= 40 && String(v).trim() === String(v) && Number.isFinite(Number(v)) && Math.abs(Number(v)) <= 1e15 && /^[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?$/.test(String(v)));
}
