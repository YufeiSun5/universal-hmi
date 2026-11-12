import React, { useEffect, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { flushSync } from 'react-dom';
import { Workbook } from '@fortune-sheet/react';
import '@fortune-sheet/react/dist/index.css';
import './style.css';

const channel = 'hmi-fortune-probe-v1';
const parentOrigin = new URLSearchParams(location.search).get('parentOrigin') || location.origin;
function emit(message) {
  const payload = { channel, ...message };
  if (window.chrome?.webview) window.chrome.webview.postMessage(payload);
  else window.parent.postMessage(JSON.stringify(payload), parentOrigin);
}
function Editor() {
  const ref = useRef(null);
  const [book, setBook] = useState(null);
  const [generation, setGeneration] = useState(0);
  const pendingLoad = useRef(null);
  useEffect(() => {
    const receive = (event) => {
      if (event.origin !== parentOrigin || event.source !== window.parent) return;
      let command;
      try { command = JSON.parse(event.data); } catch { return; }
      if (command.channel !== channel) return;
      const { id, type } = command;
      try {
        if (type === 'load') {
          pendingLoad.current = id;
          setBook(command.sheets);
          setGeneration(value => value + 1);
        } else if (type === 'set') {
          // 1.0.4's numeric setter does not recalculate dependent formulas.
          // Commit the write, then use its public calculation API explicitly.
          flushSync(() => ref.current.setCellValue(command.row, command.column, command.value));
          flushSync(() => ref.current.calculateFormula());
          emit({ type: 'response', id, result: 'updated' });
        } else if (type === 'snapshot') {
          // getAllSheets returns an internal matrix; reload requires celldata.
          const sheets = ref.current.getAllSheets().map(sheet => ref.current.getSheet({ id: sheet.id }));
          emit({ type: 'response', id, result: sheets });
        } else throw new Error(`Unknown command ${type}`);
      } catch (error) { emit({ type: 'response', id, error: String(error) }); }
    };
    window.addEventListener('message', receive);
    emit({ type: 'ready', version: '1.0.4' });
    return () => window.removeEventListener('message', receive);
  }, []);
  return book ? <Workbook key={generation} ref={ref} data={book} lang="zh"
    onOp={ops => emit({ type: 'ops', ops })}
    onChange={sheets => {
      // A mounted ref precedes the library's asynchronous data initialization.
      // Acknowledge loading only after its real sheet matrix has been created.
      if (pendingLoad.current && sheets[0]?.data) {
        const id = pendingLoad.current;
        pendingLoad.current = null;
        emit({ type: 'response', id, result: 'loaded' });
      }
      emit({ type: 'changed' });
    }} /> : <p>等待 Flutter 加载样表…</p>;
}
createRoot(document.getElementById('root')).render(<Editor />);
