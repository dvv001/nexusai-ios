/* ============================================================================
   Native Bridge Client (Nexus.native) — bundled-app only.
   Exposes iOS Calendar / Reminders / Notifications / Speech to the agent
   engine as a pseudo MCP server named 「本机能力」. On the open web (no
   nativeBridge handler injected) `available` is false and nothing changes.
   Contract: postMessage({api, action, params}) → reply {ok:true, data} or
   {ok:false, error}; malformed payloads reject the promise instead.
   ============================================================================ */
(function (global) {
  'use strict';

  const Nexus = (global.Nexus = global.Nexus || {});
  const handler =
    (global.webkit && global.webkit.messageHandlers && global.webkit.messageHandlers.nativeBridge) || null;

  const SERVER_NAME = '本机能力';

  const TOOLS = [
    {
      name: 'calendar_today', api: 'calendar', action: 'today',
      description: '读取本机今天的日历日程（标题、起止时间、地点）',
      inputSchema: { type: 'object', properties: {} }
    },
    {
      name: 'calendar_create', api: 'calendar', action: 'create',
      description: '在本机日历新建日程（需标题与 ISO 8601 起止时间）',
      inputSchema: {
        type: 'object',
        properties: {
          title: { type: 'string', description: '日程标题' },
          startISO: { type: 'string', description: '开始时间（ISO 8601，如 2026-11-28T15:00:00+08:00）' },
          endISO: { type: 'string', description: '结束时间（ISO 8601）' },
          notes: { type: 'string', description: '备注（可选）' }
        },
        required: ['title', 'startISO', 'endISO']
      }
    },
    {
      name: 'reminders_list', api: 'reminders', action: 'list',
      description: '列出本机未完成的提醒事项',
      inputSchema: { type: 'object', properties: {} }
    },
    {
      name: 'reminders_create', api: 'reminders', action: 'create',
      description: '在本机提醒事项中新建一条提醒（可带到期时间）',
      inputSchema: {
        type: 'object',
        properties: {
          title: { type: 'string', description: '提醒标题' },
          dueISO: { type: 'string', description: '到期时间（ISO 8601，可选）' },
          notes: { type: 'string', description: '备注（可选）' }
        },
        required: ['title']
      }
    },
    {
      name: 'notify_now', api: 'notify', action: 'now',
      description: '立即在本机发出一条通知（标题 + 正文）',
      inputSchema: {
        type: 'object',
        properties: {
          title: { type: 'string', description: '通知标题' },
          body: { type: 'string', description: '通知正文' }
        },
        required: ['title', 'body']
      }
    },
    {
      name: 'speak_say', api: 'speak', action: 'say',
      description: '用本机语音朗读一段文字（默认中文）',
      inputSchema: {
        type: 'object',
        properties: {
          text: { type: 'string', description: '要朗读的文字' },
          lang: { type: 'string', description: '语言代码（可选，默认 zh-CN）' }
        },
        required: ['text']
      }
    }
  ];

  async function call(api, action, params) {
    if (!handler) throw new Error('本机能力不可用：原生桥未注入（仅内置 App 可用）');
    let reply;
    try {
      reply = await handler.postMessage({ api, action, params: params || {} });
    } catch (e) {
      throw new Error((e && e.message) || String(e || '原生桥无响应'));
    }
    if (reply && reply.ok) return reply.data;
    throw new Error((reply && reply.error) || '本机调用失败');
  }

  async function callTool(name, args) {
    const tool = TOOLS.find((t) => t.name === name);
    if (!tool) throw new Error(`本机工具不存在：${name}`);
    return call(tool.api, tool.action, args || {});
  }

  Nexus.native = {
    available: Boolean(handler),
    SERVER_NAME,
    TOOLS,
    call,
    callTool
  };

  // Settings-page status line (bundled app only; stays empty on the web).
  if (handler) {
    const paint = () => {
      const el = document.getElementById('nativeBridgeStatus');
      if (el) {
        el.textContent = '本机能力已启用：日历 · 提醒事项 · 通知 · 语音朗读（智能体可通过「本机能力」工具调用）';
      }
    };
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', paint);
    else paint();
  }
})(window);
