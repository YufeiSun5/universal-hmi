import {api, defaultContext, execFunctionGroup, groupValuesRefresh} from '@fortune-sheet/core';
import {coordinates, numeric} from './sync.mjs';

// Server values and formula caches are remote operations. They must not enter
// FortuneSheet's local undo stack or split one user edit into display-only undo.
export function remoteOperations(sheets, cells) {
 const ctx=defaultContext({globalCache:{}});
 ctx.luckysheetfile=structuredClone(sheets);
 ctx.currentSheetId=sheets[0].id;
 for(const cell of cells){
  const [r,c]=coordinates(cell.address);
  api.setCellValue(ctx,r,c,cell.value===''?null:numeric(cell.value)?Number(cell.value):cell.value,null);
  for(const [key,value] of Object.entries(cell.format||{}))api.setCellFormat(ctx,r,c,key==='nf'?'ct':key,key==='nf'?{fa:value,t:numeric(cell.value)?'n':'g'}:value);
 }
 // Row-order evaluation leaves top-of-sheet month/season totals empty when
 // their daily formulas appear below them. Use the engine's dependency graph
 // so the same update publishes the readings, daily results and all rollups.
 ctx.formulaCache.formulaCellInfoMap={};
 ctx.formulaCache.execFunctionGlobalData={};
 execFunctionGroup(ctx,0,0,null,ctx.currentSheetId,ctx.luckysheetfile[0].data,true);
 groupValuesRefresh(ctx);
 const before=sheets[0].data,after=ctx.luckysheetfile[0].data,ops=[];
 for(let r=0;r<after.length;r++)for(let c=0;c<after[r].length;c++)if(JSON.stringify(before[r]?.[c])!==JSON.stringify(after[r][c]))ops.push({op:'replace',id:ctx.currentSheetId,path:['data',r,c],value:after[r][c]});
 return ops;
}
