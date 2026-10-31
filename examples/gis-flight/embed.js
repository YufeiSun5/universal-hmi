'use strict';
const box = document.getElementById('frame-wrap');
document.querySelectorAll('button').forEach(button => button.addEventListener('click', () => {
  box.style.width = button.dataset.width + 'px';
  box.style.height = button.dataset.height + 'px';
  document.querySelectorAll('button').forEach(other => other.setAttribute('aria-pressed', String(other === button)));
}));
new ResizeObserver(() => {
  document.getElementById('result').textContent = Math.round(box.clientWidth) + ' × ' + Math.round(box.clientHeight);
}).observe(box);
