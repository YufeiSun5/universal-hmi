// WebView2 delivers an object on chrome.webview; an iframe receives a string
// on window with an origin/source. Do not apply iframe identity to native events.
export function listenToHost(target, channel, receive) {
 const decode=data=>{
  let message;try{message=typeof data==='string'?JSON.parse(data):data;}catch{return;}
  if(message&&typeof message==='object'&&message.channel===channel)receive(message);
 };
 const fromWindow=event=>{
  if(event.origin!==target.location.origin||event.source!==target.parent)return;
  decode(event.data);
 };
 const fromNative=event=>decode(event.data);
 const native=target.chrome?.webview;
 target.addEventListener('message',fromWindow);
 native?.addEventListener('message',fromNative);
 return()=>{
  target.removeEventListener('message',fromWindow);
  native?.removeEventListener('message',fromNative);
 };
}
