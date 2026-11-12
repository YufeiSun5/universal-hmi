import {address,cellFormat,numeric,sameFormat} from './sync.mjs';

// Serializing acquire/renew/release prevents a late renewal restoring a lock
// after leave, or an old selection replacing the latest one on the server.
export class LeaseQueue {
  tail=Promise.resolve();
  run(action){
    const result=this.tail.then(action);
    this.tail=result.catch(()=>{});
    return result;
  }
}

export function observedCells(sheet,specs){
  return new Map(specs.filter(spec=>!(spec.v.mc&&spec.v.mc.rs==null)).map(spec=>{
    const v=sheet.data?.[spec.r]?.[spec.c];
    return [address(spec.r,spec.c),{value:v?.f||String(v?.v??''),format:cellFormat(v||{})}];
  }));
}

export function changedCells(before,after){
  const result=[];
  for(const [address,cell] of after){
    const old=before?.get(address);
    if(!old)continue;
    const sameValue=cell.value===old.value||(cell.value!==''&&old.value!==''&&numeric(cell.value)&&numeric(old.value)&&Number(cell.value)===Number(old.value));
    if(!sameValue||!sameFormat(cell.format,old.format))result.push({address,...cell});
  }
  return result;
}
