import Foundation

/// 浏览器内 Web SSH 终端页（xterm.js + 本地桥 `/v1/app/screen|stream|shell`）。
/// 由 `GET /webssh` / `GET /v1/app/webssh` 返回；鉴权 token 走 query / header。
enum WebSSHPage {
    static func html() -> String {
        // 内联完整页面，零本地静态资源依赖；xterm 从 jsDelivr CDN 加载。
        // token/session/host_id 由前端从 location.search 解析。
        return #"""
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover"/>
<title>PixShell Web SSH</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/css/xterm.min.css"/>
<style>
  :root {
    --bg: #0d1117;
    --panel: #161b22;
    --border: #30363d;
    --text: #e6edf3;
    --muted: #8b949e;
    --accent: #58a6ff;
    --danger: #f85149;
    --ok: #3fb950;
    --ink-bg: #1a1a1a;
    --ink-panel: #242424;
    --ink-border: #3a3a3a;
    --ink-text: #f0efe6;
    --ink-muted: #9a9688;
    --ink-accent: #c4a574;
  }
  * { box-sizing: border-box; }
  html, body {
    margin: 0; height: 100%;
    background: var(--bg); color: var(--text);
    font: 13px/1.4 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
  }
  body.ink {
    --bg: var(--ink-bg); --panel: var(--ink-panel); --border: var(--ink-border);
    --text: var(--ink-text); --muted: var(--ink-muted); --accent: var(--ink-accent);
  }
  #app { display: flex; flex-direction: column; height: 100%; min-height: 100dvh; }
  header {
    display: flex; align-items: center; gap: 10px; flex-wrap: wrap;
    padding: 8px 12px; background: var(--panel); border-bottom: 1px solid var(--border);
  }
  header .brand { font-weight: 600; letter-spacing: .02em; white-space: nowrap; }
  header .meta { color: var(--muted); font-size: 12px; flex: 1; min-width: 120px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--muted); flex: 0 0 auto; }
  .dot.ok { background: var(--ok); box-shadow: 0 0 6px color-mix(in srgb, var(--ok) 60%, transparent); }
  .dot.err { background: var(--danger); }
  .dot.busy { background: var(--accent); animation: pulse 1.2s ease-in-out infinite; }
  @keyframes pulse { 50% { opacity: .45; } }
  button, select {
    appearance: none; border: 1px solid var(--border); background: var(--bg); color: var(--text);
    border-radius: 6px; padding: 5px 10px; font: inherit; cursor: pointer;
  }
  button:hover, select:hover { border-color: var(--accent); }
  button:disabled { opacity: .45; cursor: not-allowed; }
  #term-wrap {
    flex: 1; min-height: 0; padding: 8px; background: var(--bg);
  }
  #term {
    width: 100%; height: 100%; border: 1px solid var(--border); border-radius: 8px;
    overflow: hidden; background: #0b0e14;
  }
  body.ink #term { background: #14110e; }
  footer {
    display: flex; gap: 12px; flex-wrap: wrap; align-items: center;
    padding: 6px 12px; border-top: 1px solid var(--border); background: var(--panel);
    color: var(--muted); font-size: 11px;
  }
  footer code { color: var(--text); }
  @media (max-width: 640px) {
    header { gap: 6px; padding: 6px 8px; }
    button, select { padding: 6px 8px; }
    #term-wrap { padding: 4px; }
  }
</style>
</head>
<body>
<div id="app">
  <header>
    <span class="brand">PixShell Web SSH</span>
    <span class="dot" id="statusDot" title="状态"></span>
    <span class="meta" id="meta">初始化…</span>
    <select id="sessionSelect" title="会话"></select>
    <button type="button" id="btnRefresh" title="刷新会话列表">刷新</button>
    <button type="button" id="btnTheme" title="切换 dark / ink">主题</button>
    <button type="button" id="btnClear" title="清本地终端">清屏</button>
  </header>
  <div id="term-wrap"><div id="term"></div></div>
  <footer>
    <span>token 鉴权 · 仅 127.0.0.1</span>
    <span>轮询 <code>/v1/app/stream</code> · 输入 <code>/v1/app/shell</code></span>
    <span id="footHint"></span>
  </footer>
</div>
<script src="https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/lib/xterm.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/@xterm/addon-fit@0.10.0/lib/addon-fit.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/@xterm/addon-web-links@0.11.0/lib/addon-web-links.min.js"></script>
<script>
(function () {
  const qs = new URLSearchParams(location.search);
  const TOKEN = (qs.get('token') || '').trim();
  let session = parseInt(qs.get('session') || qs.get('s') || '0', 10);
  if (!Number.isFinite(session) || session < 0) session = 0;
  const hostId = (qs.get('host_id') || qs.get('hostId') || qs.get('id') || '').trim();
  const themeKey = 'pixshell.webssh.theme';
  const ink = (localStorage.getItem(themeKey) || 'dark') === 'ink';
  if (ink) document.body.classList.add('ink');

  const $ = (id) => document.getElementById(id);
  const meta = $('meta');
  const foot = $('footHint');
  const statusDot = $('statusDot');
  const sessionSelect = $('sessionSelect');

  function setStatus(kind, text) {
    statusDot.className = 'dot' + (kind ? ' ' + kind : '');
    if (text) meta.textContent = text;
  }

  if (!TOKEN) {
    setStatus('err', '缺少 token。请用菜单「Web SSH 网页终端…」打开，或附加 ?token=…');
    return;
  }

  const term = new Terminal({
    cursorBlink: true,
    convertEol: true,
    fontFamily: 'Menlo, Monaco, "SF Mono", Consolas, "Courier New", monospace',
    fontSize: window.innerWidth < 640 ? 12 : 13,
    scrollback: 5000,
    theme: ink ? {
      background: '#14110e', foreground: '#f0efe6', cursor: '#c4a574',
      selectionBackground: '#3a3428', black: '#1a1a1a', red: '#c45c4a',
      green: '#7a9e6a', yellow: '#c4a574', blue: '#6a8e9e', magenta: '#9e6a8e',
      cyan: '#6a9e9e', white: '#e8e4d8', brightBlack: '#5a5648',
      brightRed: '#e07060', brightGreen: '#9ec08a', brightYellow: '#e0c090',
      brightBlue: '#8ab0c0', brightMagenta: '#c08ab0', brightCyan: '#8ac0c0', brightWhite: '#fffaf0'
    } : {
      background: '#0b0e14', foreground: '#e6edf3', cursor: '#58a6ff',
      selectionBackground: '#264f78', black: '#0d1117', red: '#ff7b72',
      green: '#3fb950', yellow: '#d29922', blue: '#58a6ff', magenta: '#bc8cff',
      cyan: '#39c5cf', white: '#e6edf3', brightBlack: '#6e7681',
      brightRed: '#ffa198', brightGreen: '#56d364', brightYellow: '#e3b341',
      brightBlue: '#79c0ff', brightMagenta: '#d2a8ff', brightCyan: '#56d4dd', brightWhite: '#ffffff'
    }
  });
  const fit = new FitAddon.FitAddon();
  term.loadAddon(fit);
  term.loadAddon(new WebLinksAddon.WebLinksAddon());
  term.open($('term'));
  fit.fit();

  const api = {
    async req(method, path, body, extraQuery) {
      const u = new URL(path, location.origin);
      u.searchParams.set('token', TOKEN);
      if (extraQuery) Object.entries(extraQuery).forEach(([k, v]) => {
        if (v !== undefined && v !== null && v !== '') u.searchParams.set(k, String(v));
      });
      const opt = {
        method,
        headers: {
          'Authorization': 'Bearer ' + TOKEN,
          'X-PixShell-Token': TOKEN
        },
        cache: 'no-store'
      };
      if (body !== undefined) {
        opt.headers['Content-Type'] = 'application/json';
        opt.body = JSON.stringify(body);
      }
      const r = await fetch(u.toString(), opt);
      const text = await r.text();
      let json = null;
      try { json = JSON.parse(text); } catch (_) {}
      if (!r.ok) {
        const err = (json && (json.error || json.message)) || text || ('HTTP ' + r.status);
        throw new Error(err);
      }
      return json;
    }
  };

  let lastCursor = null;
  let lastText = '';
  let polling = false;
  let pollTimer = null;
  let writing = false;

  function schedulePoll(ms) {
    clearTimeout(pollTimer);
    pollTimer = setTimeout(tick, ms);
  }

  async function tick() {
    if (polling) return;
    polling = true;
    try {
      const data = await api.req('GET', '/v1/app/stream', undefined, {
        session: session,
        lines: 400
      });
      const text = data.text || '';
      const cursor = data.cursor != null ? String(data.cursor) : null;
      if (cursor !== null && cursor === lastCursor) {
        // 无变化
      } else if (text !== lastText) {
        // 全量重绘（screen 是环形缓冲快照，不是增量流）
        term.reset();
        term.write(text.replace(/\r?\n/g, '\r\n'));
        lastText = text;
        lastCursor = cursor;
      } else {
        lastCursor = cursor;
      }
      setStatus('ok', '会话 #' + session + (data.totalLines != null ? ' · ' + data.totalLines + ' 行' : ''));
      foot.textContent = new Date().toLocaleTimeString() + ' 已同步';
      schedulePoll(280);
    } catch (e) {
      setStatus('err', String(e.message || e));
      schedulePoll(1200);
    } finally {
      polling = false;
    }
  }

  async function refreshSessions() {
    try {
      const data = await api.req('GET', '/v1/app/sessions');
      const list = data.sessions || [];
      sessionSelect.innerHTML = '';
      if (!list.length) {
        const o = document.createElement('option');
        o.value = '0'; o.textContent = '（无会话）';
        sessionSelect.appendChild(o);
        setStatus('busy', '暂无打开的会话 — 先在 PixShell 里连上主机，或传 host_id');
        return list;
      }
      list.forEach((s, i) => {
        const o = document.createElement('option');
        const id = (s.session != null ? s.session : i);
        o.value = String(id);
        const title = s.title || ((s.username || '') + '@' + (s.host || '') || ('会话 ' + id));
        const mark = s.active ? ' ★' : (s.connected ? '' : ' (断)');
        o.textContent = '#' + id + ' ' + title + mark;
        if (Number(id) === session) o.selected = true;
        sessionSelect.appendChild(o);
      });
      if (!list.some(s => Number(s.session != null ? s.session : 0) === session)) {
        session = Number(list[0].session != null ? list[0].session : 0);
        sessionSelect.value = String(session);
      }
      return list;
    } catch (e) {
      setStatus('err', '列会话失败: ' + (e.message || e));
      return [];
    }
  }

  async function maybeConnectHost() {
    if (!hostId) return;
    setStatus('busy', '正在连接 host_id=' + hostId + ' …');
    try {
      const data = await api.req('POST', '/v1/app/connect', { host_id: hostId });
      if (data.session != null) session = Number(data.session);
      setStatus('ok', '已连接 · 会话 #' + session);
      await refreshSessions();
    } catch (e) {
      setStatus('err', '连接失败: ' + (e.message || e));
    }
  }

  // 输入：xterm onData → POST /v1/app/shell（newline=false，原样转发含退格/控制序列）
  term.onData(async (data) => {
    if (writing) {
      // 简单串行：极快连按仍按序发
    }
    writing = true;
    try {
      await api.req('POST', '/v1/app/shell', {
        session: session,
        text: data,
        newline: false
      });
      // 输入后略加快下一轮读屏
      schedulePoll(80);
    } catch (e) {
      setStatus('err', '写入失败: ' + (e.message || e));
    } finally {
      writing = false;
    }
  });

  sessionSelect.addEventListener('change', () => {
    session = parseInt(sessionSelect.value, 10) || 0;
    lastCursor = null;
    lastText = '';
    term.reset();
    const u = new URL(location.href);
    u.searchParams.set('session', String(session));
    history.replaceState(null, '', u.toString());
    schedulePoll(50);
  });
  $('btnRefresh').addEventListener('click', () => { refreshSessions().then(() => schedulePoll(50)); });
  $('btnClear').addEventListener('click', () => { term.clear(); });
  $('btnTheme').addEventListener('click', () => {
    const next = document.body.classList.contains('ink') ? 'dark' : 'ink';
    localStorage.setItem(themeKey, next);
    location.reload();
  });

  window.addEventListener('resize', () => {
    try { fit.fit(); } catch (_) {}
  });

  // 启动
  (async function boot() {
    setStatus('busy', '连接本地桥…');
    try {
      await api.req('GET', '/v1/health');
    } catch (e) {
      setStatus('err', '桥不可达: ' + (e.message || e));
      return;
    }
    await maybeConnectHost();
    await refreshSessions();
    schedulePoll(50);
    term.focus();
  })();
})();
</script>
</body>
</html>
"""#
    }
}
