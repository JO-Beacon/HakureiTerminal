const baseUrl = (process.argv[2] ?? 'http://127.0.0.1:8765').replace(/\/$/, '');
const token = process.env.GENSOKYOAI_RUNTIME_TOKEN?.trim() ?? '';
const headers = {
  'content-type': 'application/json',
  ...(token ? { authorization: `Bearer ${token}` } : {}),
};
let requestId = 1;

async function rpc(method, params = {}) {
  const response = await fetch(`${baseUrl}/rpc`, {
    method: 'POST',
    headers,
    body: JSON.stringify({ id: `live-smoke-${requestId++}`, method, params }),
  });
  const envelope = await response.json();
  if (!response.ok || envelope.ok !== true) {
    const code = envelope.error?.code ?? envelope.error_code ?? 'rpc_error';
    throw new Error(`${method} failed (${code})`);
  }
  if (envelope.result?.ok === false) {
    const code = envelope.result.error_code ?? 'runtime_error';
    throw new Error(`${method} failed (${code})`);
  }
  return envelope.result;
}

function openSocket() {
  const wsUrl = `${baseUrl.replace(/^http/, 'ws')}/ws`;
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(wsUrl);
    socket.addEventListener('open', () => resolve(socket), { once: true });
    socket.addEventListener('error', () => reject(new Error('WebSocket connection failed')), {
      once: true,
    });
  });
}

function stream(socket, message, { cancelImmediately = false } = {}) {
  return new Promise((resolve, reject) => {
    const id = `live-smoke-stream-${requestId++}`;
    const requestedStreamId = `${id}-requested`;
    let serverStreamId = requestedStreamId;
    let content = '';
    let cancelSent = false;
    const timeout = setTimeout(() => finish(new Error('stream timed out')), 120000);

    function finish(error, result) {
      clearTimeout(timeout);
      socket.removeEventListener('message', onMessage);
      if (error) reject(error);
      else resolve(result);
    }

    function onMessage(event) {
      const frame = JSON.parse(event.data);
      if (`${frame.id}` !== id) return;
      if (frame.ok === false) {
        finish(new Error(`stream failed (${frame.error?.code ?? 'stream_error'})`));
        return;
      }
      if (frame.stream_id) serverStreamId = `${frame.stream_id}`;
      if (frame.event?.type === 'content') content += frame.event.content ?? '';
      if (frame.event?.type === 'cancelled') {
        finish(null, { cancelled: true, content, serverStreamId });
        return;
      }
      if (frame.event?.type === 'error') {
        const eventError = frame.event.error ?? {};
        const code =
          eventError.code ??
          eventError.error_code ??
          frame.event.error_code ??
          'stream_error';
        finish(new Error(`stream event failed (${code})`));
        return;
      }
      if (frame.done === true) {
        finish(null, {
          completed: true,
          cancelled: false,
          content: frame.result?.content ?? content,
          serverStreamId,
        });
      }
    }

    socket.addEventListener('message', onMessage);
    socket.send(JSON.stringify({
      id,
      method: 'agent.send_message_stream',
      params: { message, stream_id: requestedStreamId },
    }));
    if (cancelImmediately) {
      queueMicrotask(() => {
        if (cancelSent) return;
        cancelSent = true;
        const cancelId = `live-smoke-cancel-${requestId++}`;
        socket.send(JSON.stringify({
          id: cancelId,
          method: 'runtime.cancel_stream',
          params: { stream_id: requestedStreamId },
        }));
      });
    }
  });
}

const original = await rpc('session.current');
const created = await rpc('session.create');
const testSessionId = created?.session_id;
if (!testSessionId) throw new Error('session.create returned no session_id');
const createdCurrent = await rpc('session.current');
const createdList = await rpc('session.list');
const emptyHistory = await rpc('session.messages', { session_id: testSessionId });
if (createdCurrent?.session_id !== testSessionId) {
  throw new Error('session.create did not activate the test session');
}
if (!createdList.some((item) => item.session_id === testSessionId)) {
  throw new Error('session.list did not include the test session after creation');
}
if ((emptyHistory?.messages ?? []).length !== 0) {
  throw new Error('new test session was not empty');
}

const socket = await openSocket();
try {
  const marker = `HakureiTerminal live smoke ${Date.now()}`;
  const completed = await stream(socket, `${marker}。请用一句简短的话回复。`);
  if (!completed.completed || completed.cancelled) {
    throw new Error('stream did not return a valid completion frame');
  }

  const completedCurrent = await rpc('session.current');
  const completedList = await rpc('session.list');
  if (completedCurrent?.session_id !== testSessionId) {
    throw new Error('stream completion changed the active session');
  }
  if (!completedList.some((item) => item.session_id === testSessionId)) {
    throw new Error('stream completion removed the test session from session.list');
  }
  const reconciliationStartedAt = Date.now();
  const observations = [];
  let messages = [];
  for (const delay of [0, 50, 100, 250, 500, 1000, 2000]) {
    if (delay) await new Promise((resolve) => setTimeout(resolve, delay));
    const history = await rpc('session.messages', { session_id: testSessionId });
    messages = history?.messages ?? [];
    const hasUser = messages.some(
      (item) => item.role === 'user' && item.content?.includes(marker),
    );
    observations.push({ elapsedMs: Date.now() - reconciliationStartedAt, count: messages.length, hasUser });
    if (hasUser) break;
  }
  const historyConverged =
    messages.some((item) => item.role === 'user' && item.content?.includes(marker)) &&
    (!completed.content.trim() ||
      messages.some(
        (item) => item.role === 'assistant' && item.content === completed.content,
      ));

  const cancelled = await stream(
    socket,
    '请生成一段较长的测试回复，用于验证取消流。',
    { cancelImmediately: true },
  );
  if (!cancelled.cancelled) {
    throw new Error('cancel smoke completed before cancellation was observed');
  }

  console.log(JSON.stringify({
    ok: true,
    completedStream: true,
    assistantContent: completed.content.trim().length > 0,
    authoritativeHistory: historyConverged,
    cancelledStream: true,
    reconciliationObservations: observations,
  }));
} finally {
  socket.close();
  await rpc('session.delete', { session_id: testSessionId }).catch(() => {});
  if (original?.session_id) {
    await rpc('session.resume', { session_id: original.session_id }).catch(() => {});
  }
}
