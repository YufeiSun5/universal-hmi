import {defineConfig} from 'vite';

export default defineConfig({
 plugins:[{
  name:'fortune-readonly-update-guard',
  enforce:'pre',
  transform(code,id){
   if(!/\/@fortune-sheet\/react\/dist\/index(?:\.esm)?\.js$/.test(id.replaceAll('\\','/')))return;
   // FortuneSheet 1.0.4 updates context on every readonly layout pass even
   // without a formula highlight. Its group refresh mutates sheet arrays,
   // retriggering that layout effect until React aborts the render.
   const before='if (!context.allowEdit) {\n      setContext(function (ctx) {';
   if(code.split(before).length!==2)throw new Error('Review FortuneSheet readonly compatibility patch after dependency changes');
   return {code:code.replace(before,'if (!context.allowEdit && context.forceFormulaRef) {\n      setContext(function (ctx) {'),map:null};
  },
 }],
});
