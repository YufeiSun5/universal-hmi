// 在承载页的“打开时”和唯一的 2 秒定时器中使用同一调用。
// 先建自定义脚本 UniversalHmiKPBridgeTick，参数为 (WebContainer1)，
// 内容使用 kp-page-timer.js；身份凭据接口仍按 KP 联动合同配置。
$Function.UniversalHmiKPBridgeTick(WebContainer1);
