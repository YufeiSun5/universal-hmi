import fs from 'node:fs/promises';
import path from 'node:path';
const lock=JSON.parse(await fs.readFile(new URL('./package-lock.json',import.meta.url),'utf8'));
const root=path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/,'$1'));
const parts=['Third-party notices for the locally bundled Total Statistics Reports editor.\nVersions are pinned in tools/total_reports/package-lock.json.\n'];
for(const [dir,meta] of Object.entries(lock.packages)){
 if(!dir||meta.dev||meta.optional)continue;
 const folder=path.join(root,dir),pkg=JSON.parse(await fs.readFile(path.join(folder,'package.json'),'utf8'));
 const names=(await fs.readdir(folder)).filter(n=>/^(licen[cs]e|copying|notice)(\.|$)/i.test(n));
 const texts=[];
 for(const name of names){const file=path.join(folder,name);if((await fs.stat(file)).isFile())texts.push(await fs.readFile(file,'utf8'));}
 if(pkg.name==='@fortune-sheet/core'||pkg.name==='@fortune-sheet/react')texts.push(await fs.readFile(path.join(root,'licenses/FortuneSheet.txt'),'utf8'));
 if(!texts.length)throw new Error(`Missing license text: ${pkg.name}`);
 parts.push(`\n===== ${pkg.name} ${pkg.version} (${pkg.license||meta.license||''}) =====\n${texts.join('\n')}`);
}
await fs.writeFile(path.join(root,'../../app/web/total-reports/THIRD_PARTY_NOTICES.txt'),parts.join('\n'));
