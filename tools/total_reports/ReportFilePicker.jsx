import React,{useRef} from 'react';

// Keep the native file dialog, while using the same accessible button styling
// and sizing as the rest of the report workspace.
export function ReportFilePicker({label='文件',title=label,accept,disabled=false,fileName='',onFile}){
 const input=useRef(null);
 return <div className="report-file-field"><span>{title}</span><div className="report-file-picker">
  <input ref={input} type="file" aria-label={label} accept={accept} disabled={disabled} hidden onChange={e=>onFile(e.target.files?.[0])}/>
  <button type="button" disabled={disabled} onClick={()=>input.current?.click()}>选择文件</button>
  <span className="report-file-name" title={fileName||'未选择文件'}>{fileName||'未选择文件'}</span>
 </div></div>;
}
