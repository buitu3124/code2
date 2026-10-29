// Screenshots several poses and tiles them into one contact sheet.
// node sheet.mjs out.png SIGN[:ms] ...
import puppeteer from 'puppeteer-core';
import fs from 'fs';
const [outFile, ...items] = process.argv.slice(2);
const browser = await puppeteer.launch({
  executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe',
  args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'],
});
const imgs = [];
for (const arg of items) {
  const [sign, ms] = arg.split(':');
  const page = await browser.newPage();
  await page.setViewport({ width: 300, height: 380 });
  let ready = false;
  page.on('console', (m) => { const t = m.text(); if (t.includes('"ready"')) ready = true; if (t.includes("error") || t.includes("scale")) console.log(sign, t.slice(0, 300)); });
  page.on('pageerror', (e) => console.log(sign, 'pageerror:', e.message));
  await page.goto(`http://127.0.0.1:8765/index.html?test=${sign}${ms ? '&ms=' + ms : ''}`);
  for (let i = 0; i < 120 && !ready; i++) await new Promise((r) => setTimeout(r, 200));
  await new Promise((r) => setTimeout(r, 1200));
  imgs.push([arg, (await page.screenshot({ encoding: 'base64' }))]);
  await page.close();
}
const cols = 4;
const html = `<body style="margin:0;background:#000;display:grid;grid-template-columns:repeat(${cols},300px);gap:2px;font:14px sans-serif;color:#fff">` +
  imgs.map(([n, b]) => `<div style="position:relative"><img src="data:image/png;base64,${b}"><span style="position:absolute;left:6px;top:4px;background:#000a;padding:2px 6px">${n}</span></div>`).join('') + '</body>';
const page = await browser.newPage();
await page.setViewport({ width: cols * 302, height: Math.ceil(imgs.length / cols) * 382 });
await page.setContent(html);
await page.screenshot({ path: outFile, fullPage: true });
await browser.close();
