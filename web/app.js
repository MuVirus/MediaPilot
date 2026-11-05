// MediaPilot reference browser client.
//
// Responsibilities:
// - capture the microphone at 16 kHz mono PCM16 and stream it to the gateway
// - play 24 kHz mono PCM16 deltas in order
// - stop playback immediately on `playback.clear`
// - reconnect with backoff after a retryable disconnect
//
// The gateway owns VAD and turn detection, so this client never sends
// `input_audio_buffer.commit`; it just streams while the mic is on.

const INPUT_RATE = 16000;
const OUTPUT_RATE = 24000;
const MAX_BACKOFF_MS = 8000;
const MAX_RECONNECT_ATTEMPTS = 8;

const els = {
  start: document.getElementById("start"),
  stop: document.getElementById("stop"),
  interrupt: document.getElementById("interrupt"),
  status: document.getElementById("status"),
  transcript: document.getElementById("transcript"),
  log: document.getElementById("log"),
  permission: document.getElementById("permission"),
  permissionText: document.getElementById("permission-text"),
  agent: document.getElementById("agent"),
  agentState: document.getElementById("agent-state"),
  agentStep: document.getElementById("agent-step"),
  agentText: document.getElementById("agent-text"),
};

let ws = null;
let captureContext = null;
let playbackContext = null;
let micStream = null;
let workletNode = null;
let sourceNode = null;
let nextPlayAt = 0;
const activeSources = new Set();

let running = false;
let fatal = false;
let reconnectAttempt = 0;
let reconnectTimer = null;
let sessionId = "";
let receivedAudioSeconds = 0;
let taskLine = "";
let assistantLine = null;
let userLine = null;
let permissionRequestId = "";
let permissionTimer = null;
let agentStartedAt = 0;
let agentTimer = null;

function log(message) {
  const line = `${new Date().toLocaleTimeString()} ${message}`;
  els.log.textContent = `${line}\n${els.log.textContent}`.slice(0, 8000);
}

function setStatus(text) {
  els.status.textContent = text;
}

function refreshStatus() {
  if (!running) return;
  if (!ws || ws.readyState !== WebSocket.OPEN) return;
  const parts = [
    `已接收 ${receivedAudioSeconds.toFixed(1)}s 音频`,
  ];
  if (sessionId) parts.push(sessionId);
  if (taskLine) parts.push(taskLine);
  setStatus(`已连接 · ${parts.join(" · ")}`);
}

function setRunning(value) {
  running = value;
  els.start.disabled = value;
  els.stop.disabled = !value;
  els.interrupt.disabled = !value;
}

function base64ToBytes(base64) {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function bytesToBase64(bytes) {
  let binary = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

function int16ToBase64(int16) {
  return bytesToBase64(
    new Uint8Array(int16.buffer, int16.byteOffset, int16.byteLength),
  );
}

function lineFor(role) {
  const isUser = role === "user";
  if (isUser && userLine) return userLine;
  if (!isUser && assistantLine) return assistantLine;
  const div = document.createElement("div");
  const label = document.createElement("span");
  label.className = "role";
  label.textContent = isUser ? "你" : "助手";
  const text = document.createElement("span");
  div.append(label, text);
  els.transcript.append(div);
  if (isUser) userLine = text;
  else assistantLine = text;
  return text;
}

function resetLines() {
  userLine = null;
  assistantLine = null;
}

function stopPlayback() {
  for (const source of activeSources) {
    try {
      source.stop();
    } catch {
      // already stopped
    }
  }
  activeSources.clear();
  nextPlayAt = 0;
}

function playPcm16(bytes) {
  if (!playbackContext) return;
  const samples = new Int16Array(
    bytes.buffer,
    bytes.byteOffset,
    Math.floor(bytes.byteLength / 2),
  );
  const buffer = playbackContext.createBuffer(1, samples.length, OUTPUT_RATE);
  const channel = buffer.getChannelData(0);
  for (let i = 0; i < samples.length; i++) channel[i] = samples[i] / 0x8000;

  const source = playbackContext.createBufferSource();
  source.buffer = buffer;
  source.connect(playbackContext.destination);
  const now = playbackContext.currentTime;
  const startAt = Math.max(now, nextPlayAt);
  source.start(startAt);
  nextPlayAt = startAt + buffer.duration;
  activeSources.add(source);
  source.onended = () => activeSources.delete(source);
}

function send(event) {
  if (!ws || ws.readyState !== WebSocket.OPEN) return false;
  ws.send(JSON.stringify(event));
  return true;
}

function hidePermission() {
  permissionRequestId = "";
  if (permissionTimer) {
    clearTimeout(permissionTimer);
    permissionTimer = null;
  }
  els.permission.classList.add("hidden");
}

function showPermission(event) {
  hidePermission();
  permissionRequestId = event.requestId;
  els.permissionText.textContent = `${event.operation} · ${event.description}`;
  els.permission.classList.remove("hidden");
  log(`permission requested: ${event.operation} ${event.description}`);
  // The gateway denies on its own timeout; hide the panel slightly later so
  // the user does not see an answer that no longer applies.
  permissionTimer = setTimeout(() => {
    if (permissionRequestId === event.requestId) {
      hidePermission();
      log("permission timed out");
    }
  }, Math.max(1000, event.timeoutMs));
}

function answerPermission(decision) {
  if (!permissionRequestId) return;
  const requestId = permissionRequestId;
  hidePermission();
  if (send({ type: "permission.respond", requestId, decision })) {
    log(`permission answered: ${decision}`);
  }
}

function hideAgent() {
  agentStartedAt = 0;
  if (agentTimer) {
    clearInterval(agentTimer);
    agentTimer = null;
  }
  els.agent.classList.add("hidden");
  els.agentState.textContent = "";
  els.agentStep.textContent = "";
  els.agentText.textContent = "";
}

function showAgent() {
  if (agentStartedAt) return;
  agentStartedAt = Date.now();
  els.agent.classList.remove("hidden");
  const tick = () => {
    const seconds = ((Date.now() - agentStartedAt) / 1000).toFixed(1);
    els.agentState.textContent = `处理中 ${seconds}s`;
  };
  tick();
  agentTimer = setInterval(tick, 200);
}

function finishAgent(label) {
  if (agentTimer) {
    clearInterval(agentTimer);
    agentTimer = null;
  }
  els.agentState.textContent = label;
}

function handleServerEvent(event) {
  switch (event.type) {
    case "session.ready":
      sessionId = event.sessionId;
      reconnectAttempt = 0;
      receivedAudioSeconds = 0;
      taskLine = "";
      hideAgent();
      log(`ready session=${event.sessionId}`);
      refreshStatus();
      break;
    case "transcript.partial":
      lineFor(event.role).textContent = event.text;
      break;
    case "transcript.final":
      lineFor(event.role).textContent = event.text;
      // A finished segment is its own line. Without this, a later background
      // result would overwrite the earlier acknowledgement in the same span.
      if (event.role === "assistant") assistantLine = null;
      break;
    case "audio.delta": {
      const bytes = base64ToBytes(event.data);
      receivedAudioSeconds += bytes.byteLength / 2 / OUTPUT_RATE;
      playPcm16(bytes);
      refreshStatus();
      break;
    }
    case "playback.clear":
      log(`playback.clear reason=${event.reason}`);
      stopPlayback();
      // A new user turn starts here, so the next transcript lines are new.
      resetLines();
      if (event.reason === "user_interruption") hideAgent();
      break;
    case "task.updated":
      showAgent();
      if (event.step) els.agentStep.textContent = event.step;
      if (event.text) els.agentText.textContent = event.text;
      if (event.status === "running") {
        taskLine = event.step
          ? `代理处理中 ${event.text.length} 字 · ${event.step}`
          : `代理处理中 ${event.text.length} 字`;
      } else if (event.status === "completed") {
        taskLine = `代理完成 ${event.text.length} 字`;
        finishAgent(`完成，用时 ${((Date.now() - agentStartedAt) / 1000).toFixed(1)}s`);
        log(`task ${event.taskId} completed`);
      } else if (event.status === "cancelled") {
        taskLine = "代理已取消";
        finishAgent("已取消");
        log(`task ${event.taskId} cancelled`);
      } else {
        taskLine = "代理失败";
        finishAgent("失败");
        log(`task ${event.taskId} failed: ${event.text}`);
      }
      refreshStatus();
      break;
    case "permission.request":
      showPermission(event);
      break;
    case "permission.resolved":
      hidePermission();
      log(`permission ${event.requestId} ${event.decision} (${event.source})`);
      break;
    case "error":
      log(`error ${event.code}: ${event.message}`);
      if (!event.retryable) {
        fatal = true;
        setStatus(`不可恢复的错误：${event.code}`);
      } else {
        setStatus(`上游错误：${event.code}，等待重连`);
      }
      break;
    default:
      log(`event ${event.type}`);
  }
}

async function startCapture() {
  captureContext = new AudioContext({ sampleRate: INPUT_RATE });
  await captureContext.audioWorklet.addModule("/pcm-worklet.js");
  micStream = await navigator.mediaDevices.getUserMedia({
    audio: {
      channelCount: 1,
      echoCancellation: true,
      noiseSuppression: true,
      autoGainControl: true,
    },
  });
  sourceNode = captureContext.createMediaStreamSource(micStream);
  workletNode = new AudioWorkletNode(captureContext, "pcm-capture");
  workletNode.port.onmessage = (message) => {
    send({
      type: "input.audio.append",
      data: int16ToBase64(message.data),
      format: "pcm16",
      sampleRate: INPUT_RATE,
      channels: 1,
    });
  };
  sourceNode.connect(workletNode);
  // The worklet must reach a destination for the graph to pull audio, but it
  // must not be audible. A zero-gain node keeps it silent.
  const mute = captureContext.createGain();
  mute.gain.value = 0;
  workletNode.connect(mute);
  mute.connect(captureContext.destination);
}

function socketUrl() {
  const scheme = location.protocol === "https:" ? "wss" : "ws";
  return `${scheme}://${location.host}/api/realtime`;
}

function connectSocket() {
  const socket = new WebSocket(socketUrl());
  ws = socket;
  socket.onopen = () => {
    if (ws !== socket) return;
    send({
      type: "session.hello",
      requestId: `c-${Date.now()}`,
      protocolVersion: "0.6.0",
      capabilities: [
        "realtime.audio-in",
        "realtime.audio-out",
        "realtime.text-in",
        "realtime.interrupt",
        "realtime.playback-clear",
        "realtime.task",
        "realtime.permission",
      ],
    });
    log("socket open, hello sent");
    setStatus("握手中…");
  };
  socket.onmessage = (message) => {
    let event;
    try {
      event = JSON.parse(message.data);
    } catch {
      log("ignored non-JSON frame");
      return;
    }
    handleServerEvent(event);
  };
  socket.onclose = () => {
    if (ws !== socket) return;
    ws = null;
    onSocketClosed();
  };
  socket.onerror = () => log("socket error");
}

function onSocketClosed() {
  stopPlayback();
  if (fatal) {
    setStatus("已停止：不可恢复的错误");
    setRunning(false);
    return;
  }
  if (!running) {
    setStatus("未连接");
    return;
  }
  scheduleReconnect();
}

function scheduleReconnect() {
  if (reconnectAttempt >= MAX_RECONNECT_ATTEMPTS) {
    log(`giving up after ${reconnectAttempt} attempts`);
    setStatus("重连失败，请点“开始”重试");
    teardown();
    return;
  }
  reconnectAttempt += 1;
  const delay = Math.min(
    MAX_BACKOFF_MS,
    500 * 2 ** Math.max(0, reconnectAttempt - 1),
  );
  setStatus(`连接断开，${delay} ms 后重连（第 ${reconnectAttempt} 次）`);
  log(`reconnect in ${delay} ms (attempt ${reconnectAttempt})`);
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    if (running && !fatal) connectSocket();
  }, delay);
}

function clearReconnect() {
  if (reconnectTimer !== null) {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }
}

function teardown() {
  clearReconnect();
  hidePermission();
  hideAgent();
  if (workletNode) {
    workletNode.port.onmessage = null;
    workletNode.disconnect();
    workletNode = null;
  }
  if (sourceNode) {
    sourceNode.disconnect();
    sourceNode = null;
  }
  if (micStream) {
    for (const track of micStream.getTracks()) track.stop();
    micStream = null;
  }
  if (captureContext) {
    captureContext.close();
    captureContext = null;
  }
  stopPlayback();
  if (playbackContext) {
    playbackContext.close();
    playbackContext = null;
  }
  if (ws) {
    try {
      ws.close();
    } catch {
      // already closed
    }
    ws = null;
  }
  setRunning(false);
}

async function start() {
  if (running) return;
  fatal = false;
  reconnectAttempt = 0;
  receivedAudioSeconds = 0;
  sessionId = "";
  setRunning(true);
  setStatus("连接中…");
  resetLines();
  els.transcript.textContent = "";

  try {
    playbackContext = new AudioContext({ sampleRate: OUTPUT_RATE });
    await startCapture();
    log("microphone streaming");
  } catch (error) {
    log(`microphone failed: ${error}`);
    setStatus("麦克风不可用，需要 https 或 127.0.0.1");
    teardown();
    return;
  }
  connectSocket();
}

function stop() {
  if (!running) return;
  const wasOpen = ws && ws.readyState === WebSocket.OPEN;
  if (wasOpen) send({ type: "session.close" });
  teardown();
  setStatus("未连接");
  log("stopped");
}

els.start.addEventListener("click", () => {
  start().catch((error) => {
    log(`start failed: ${error}`);
    teardown();
    setStatus("启动失败");
  });
});
els.stop.addEventListener("click", stop);
els.interrupt.addEventListener("click", () => {
  stopPlayback();
  if (send({ type: "session.interrupt" })) log("interrupt sent");
});
document.getElementById("allow-once").addEventListener("click", () => {
  answerPermission("allow_once");
});
document.getElementById("allow-task").addEventListener("click", () => {
  answerPermission("allow_task");
});
document.getElementById("allow-session").addEventListener("click", () => {
  answerPermission("allow_session");
});
document.getElementById("deny").addEventListener("click", () => {
  answerPermission("deny");
});

// Debug hook for the headless smoke test and for manual poking in devtools.
// Not part of the gateway contract.
window.mediapilot = {
  send,
  stopPlayback,
  dropSocket: () => {
    if (ws) ws.close();
  },
};
