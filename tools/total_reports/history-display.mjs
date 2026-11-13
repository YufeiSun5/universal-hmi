import {update as formatDisplay} from '@fortune-sheet/core';
import {coordinates} from './sync.mjs';

// Only the display cache is changed. Numeric values, formulas, styles and
// collaboration state never receive loading strings or provisional markers.
export function historyDisplayOperations(sheets,items,pending=new Set()) {
 const sheet=sheets[0];if(!sheet?.data)return [];
 const ops=[];
 for(const item of items){
  const [r,c]=coordinates(item.address),cell=sheet.data[r]?.[c];
  if(!cell||cell.f)continue;
  const empty=cell.v===null||cell.v===undefined||cell.v==='';
  let text=empty?'':String(formatDisplay(cell.ct?.fa||'General',cell.v));
  if(empty&&pending.has(item.address))text='加载中…';
  else if(!empty&&item.provisional)text+=' *';
  if(cell.m!==text)ops.push({op:'replace',id:sheet.id,path:['data',r,c,'m'],value:text});
 }
 return ops;
}

export function pendingHistoryCells(items){return new Set(items.filter(v=>v.eligible).map(v=>v.address));}
export function historyNotice(items){
 const live=items.filter(v=>v.provisional&&v.value!=null);
 if(!live.length)return '';
 const stamps=live.map(v=>v.sample_time).filter(Boolean).sort();
 const times=stamps.map(v=>v.replace('T',' ').replace(/(?:\.\d+)?[+]08:00$/,''));
 return `* 当期最新采样，尚未结算${times.length?`；截至 ${times[0]}${times.at(-1)!==times[0]?' ～ '+times.at(-1):''}`:''}。当日及月/季合计包含暂计值。`;
}
