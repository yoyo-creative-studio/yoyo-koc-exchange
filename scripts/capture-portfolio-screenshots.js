const fs = require('fs');

const endpoint = process.argv[2] || 'http://127.0.0.1:9223';
const baseUrl = process.argv[3] || 'http://127.0.0.1:8877';

async function connect() {
  const version = await fetch(endpoint + '/json/version').then((response) => response.json());
  const socket = new WebSocket(version.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    socket.addEventListener('open', resolve, { once: true });
    socket.addEventListener('error', reject, { once: true });
  });
  let id = 0;
  const pending = new Map();
  socket.addEventListener('message', (event) => {
    const message = JSON.parse(event.data);
    if (!message.id || !pending.has(message.id)) return;
    const { resolve, reject } = pending.get(message.id);
    pending.delete(message.id);
    if (message.error) reject(new Error(message.error.message));
    else resolve(message.result || {});
  });
  return {
    send(method, params = {}, sessionId) {
      const requestId = ++id;
      socket.send(JSON.stringify({ id: requestId, method, params, sessionId }));
      return new Promise((resolve, reject) => pending.set(requestId, { resolve, reject }));
    },
    close() { socket.close(); },
  };
}

async function delay(ms) {
  await new Promise((resolve) => setTimeout(resolve, ms));
}

async function openPage(client, url) {
  const target = await client.send('Target.createTarget', { url });
  const attached = await client.send('Target.attachToTarget', { targetId: target.targetId, flatten: true });
  const sessionId = attached.sessionId;
  await client.send('Page.enable', {}, sessionId);
  await client.send('Runtime.enable', {}, sessionId);
  await client.send('Emulation.setDeviceMetricsOverride', { width: 1440, height: 980, deviceScaleFactor: 1, mobile: false }, sessionId);
  await delay(2200);
  return sessionId;
}

async function evaluate(client, sessionId, expression) {
  return client.send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }, sessionId);
}

async function capture(client, sessionId, output) {
  const screenshot = await client.send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false }, sessionId);
  fs.writeFileSync(output, Buffer.from(screenshot.data, 'base64'));
}

const sanitizeExpression = `(() => {
  const replacements = ['Creator A','Creator B','Creator C','Creator D','Creator E','Creator F'];
  document.querySelectorAll('tbody tr').forEach((row, rowIndex) => {
    row.querySelectorAll('td').forEach((cell, cellIndex) => {
      if (cellIndex === 0) cell.textContent = replacements[rowIndex % replacements.length];
      else cell.textContent = cellIndex % 3 === 0 ? 'APPROVED' : '••••••••';
    });
  });
  document.querySelectorAll('input, textarea').forEach((field) => {
    if (field.type !== 'checkbox' && field.type !== 'radio') field.value = '';
  });
  document.querySelectorAll('[title]').forEach((node) => {
    if (/uid|address|phone|account|discord|code/i.test(node.title || '')) node.title = 'Hidden for portfolio';
  });
  const showcase = document.getElementById('showcase-sub-list');
  if (showcase) showcase.innerHTML = ['Creator A','Creator B','Creator C','Creator D'].map((name, index) => '<div style="display:grid;grid-template-columns:140px 120px 1fr auto;gap:10px;padding:10px 0;border-bottom:1px solid #c8e6c9"><strong>' + name + '</strong><span>UID ••••••••</span><span>https://social.example/work-' + (index + 1) + '</span><button style="border:1px solid #66bb6a;background:#e8f5e9;color:#2e7d32">APPROVED</button></div>').join('');
  window.scrollTo(0, 0);
})()`;

(async () => {
  const client = await connect();
  fs.mkdirSync('assets/portfolio', { recursive: true });

  const creatorSession = await openPage(client, baseUrl + '/index.html');
  await capture(client, creatorSession, 'assets/portfolio/creator-portal.png');

  const adminSession = await openPage(client, baseUrl + '/admin.html');
  await evaluate(client, adminSession, `localStorage.setItem('admin_session','logged_in'); location.reload()`);
  await delay(3500);
  await evaluate(client, adminSession, `switchTab('submissions')`);
  await delay(1800);
  await evaluate(client, adminSession, sanitizeExpression);
  await capture(client, adminSession, 'assets/portfolio/submission-review.png');

  await evaluate(client, adminSession, `switchTab('scoring')`);
  await delay(1200);
  await evaluate(client, adminSession, sanitizeExpression);
  await capture(client, adminSession, 'assets/portfolio/scoring.png');

  await evaluate(client, adminSession, `switchTab('fulfillment')`);
  await delay(1800);
  await evaluate(client, adminSession, sanitizeExpression);
  await capture(client, adminSession, 'assets/portfolio/fulfillment.png');

  client.close();
  console.log('Portfolio screenshots captured with sensitive fields masked.');
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
