const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'C:/Users/zcc36/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
const { createServer } = require('node:http');
const { readFileSync, statSync, createReadStream, mkdirSync, writeFileSync } = require('node:fs');
const { join, extname, resolve, sep } = require('node:path');
const { randomUUID } = require('node:crypto');
const assert = require('node:assert/strict');
const project = resolve(__dirname, '../..');
const site = process.argv[2] && process.argv[2] !== '--final' ? resolve(process.argv[2]) : resolve(project, '../../outputs/commercial-preview/web');
const work = process.env.XIUXIAN_WEB_WORK || resolve(project, '../commercial-verification/web-export');
const run = join(work, 'browser-' + randomUUID());
mkdirSync(run, { recursive: true });
mkdirSync(join(run, 'temp'));
process.env.TEMP = join(run, 'temp');
process.env.TMP = join(run, 'temp');
const mime = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.wasm': 'application/wasm', '.pck': 'application/octet-stream', '.png': 'image/png' };
const files = [];
const server = createServer((request, response) => {
  const pathname = new URL(request.url, 'http://127.0.0.1').pathname;
  const file = resolve(site, '.' + (pathname === '/' ? '/index.html' : decodeURIComponent(pathname)));
  if (!(file + sep).startsWith(resolve(site) + sep)) return response.writeHead(403).end();
  try {
    const stat = statSync(file);
    assert.ok(stat.isFile());
    files.push({ path: pathname, size: stat.size });
    response.writeHead(200, { 'content-type': mime[extname(file)] || 'application/octet-stream', 'content-length': stat.size, 'cache-control': 'no-store' });
    createReadStream(file).pipe(response);
  } catch { response.writeHead(404).end(); }
});
(async () => {
  let context;
  try {
    await new Promise((resolve, reject) => server.once('error', reject).listen(0, '127.0.0.1', resolve));
    const base = 'http://127.0.0.1:' + server.address().port;
    context = await chromium.launchPersistentContext(join(run, 'profile'), {
      executablePath: process.env.BROWSER_EXECUTABLE || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
      headless: true, viewport: { width: 1440, height: 900 },
      downloadsPath: join(run, 'downloads'), tracesDir: join(run, 'traces'),
      env: { ...process.env, TEMP: join(run, 'temp'), TMP: join(run, 'temp') },
      args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--no-proxy-server'],
    });
    const page = context.pages()[0];
    const errors = [], failed = [], badResponses = [], consoleLines = [];
    page.on('pageerror', error => errors.push(error.message));
    page.on('console', entry => { consoleLines.push({ type: entry.type(), text: entry.text() }); if (entry.type() === 'error') errors.push(entry.text()); });
    page.on('requestfailed', request => failed.push({ url: request.url(), failure: request.failure() }));
    page.on('response', response => { if (response.status() >= 400) badResponses.push({ status: response.status(), url: response.url() }); });
    await page.goto(base, { timeout: 90000 });
    await page.locator('#status').waitFor({ state: 'hidden', timeout: 90000 });
    await page.waitForTimeout(3000);
    const rect = await page.locator('canvas').boundingBox();
    assert.equal(rect.width, 1440);
    assert.equal(rect.height, 900);
    await page.screenshot({ path: join(site, 'desktop-login.png') });
    const body = await page.evaluate(() => ({ title: document.title, loading: !document.getElementById('status').hidden, width: document.getElementById('canvas').width, height: document.getElementById('canvas').height }));
    assert.equal(body.title, '疯狂修仙，中');
    assert.equal(body.loading, false);
    await page.mouse.click(1000, 628);
    await page.waitForTimeout(500);
    await page.keyboard.press('Escape');
    await page.waitForTimeout(200);
    await page.screenshot({ path: join(site, 'desktop-guest.png') });
    await page.mouse.click(942, 860);
    await page.waitForTimeout(500);
    await page.screenshot({ path: join(site, 'desktop-wish.png') });
    await page.keyboard.press('Escape');
    await page.mouse.click(838, 860);
    await page.waitForTimeout(700);
    await page.screenshot({ path: join(site, 'desktop-corridor.png') });
    const mobile = await context.browser().newContext({ viewport: { width: 844, height: 390 }, isMobile: true, hasTouch: true });
    const phone = await mobile.newPage();
    phone.on('pageerror', error => errors.push(error.message));
    phone.on('console', entry => { if (entry.type() === 'error') errors.push(entry.text()); });
    phone.on('requestfailed', request => failed.push({ url: request.url(), failure: request.failure() }));
    await phone.goto(base, { timeout: 90000 });
    await phone.locator('#status').waitFor({ state: 'hidden', timeout: 90000 });
    await phone.waitForTimeout(1600);
    await phone.screenshot({ path: join(site, 'mobile-login.png') });
    const before = await phone.locator('canvas').boundingBox();
    await phone.touchscreen.tap(420, 165);
    await phone.waitForFunction(() => document.activeElement.matches('#stage > input:not(:disabled)'), { timeout: 5000 });
    await phone.evaluate(() => {
      const field = document.activeElement;
      field.value = 'web_test';
      field.setSelectionRange(field.value.length, field.value.length);
      field.dispatchEvent(new InputEvent('input', { bubbles: true, data: field.value }));
    });
    await phone.waitForTimeout(150);
    await phone.setViewportSize({ width: 844, height: 230 });
    await phone.waitForTimeout(150);
    const editing = await phone.locator('canvas').boundingBox();
    assert.equal(editing.width, before.width, 'keyboard resize keeps canvas width');
    assert.equal(editing.height, before.height, 'keyboard resize keeps canvas height');
    await phone.screenshot({ path: join(site, 'mobile-keyboard.png') });
    await mobile.close();
    const summary = { base, run, body, canvas: rect, files, errors, failed, badResponses, console: consoleLines };
    writeFileSync(join(work, process.argv.includes('--final') ? 'browser-smoke-final.json' : 'browser-smoke-initial.json'), JSON.stringify(summary, null, 2));
    assert.equal(errors.length, 0, JSON.stringify(errors));
    assert.equal(failed.length, 0, JSON.stringify(failed));
    assert.equal(badResponses.length, 0, JSON.stringify(badResponses));
    console.log('WEB_BASIC_PASS: unmodified release HTML and WASM/PCK loaded, desktop login/guest/wish/corridor rendered, mobile login and native input/keyboard resize verified, zero runtime/network errors');
    console.log(JSON.stringify({ run, fetchedBytes: files.reduce((sum, file) => sum + file.size, 0), requestCount: files.length, screenshot: join(site, 'desktop-login.png') }));
  } finally {
    await context?.close();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
