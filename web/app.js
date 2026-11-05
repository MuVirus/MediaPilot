// MediaPilot reference browser client.
//
// Responsibilities:
// - capture the microphone at 16 kHz mono PCM16 and stream it to the gateway
// - play 24 kHz mono PCM16 deltas in order
// - stop playback immediately on `playback.clear`
//
// The gateway owns VAD and turn detection, so this client never sends
// `input_audio_buffer.commit`; it just streams while the mic is on.

const INPUT_RATE = 16000;
const OUTPUT_RATE = 24000;

const els = {
  start: document.getElementById("start"),
  stop: document.getElementById("stop"),
  interrupt: document.getElementById("interrupt"),
  status: document.getElementById("status"),
  transcript: document.getElementById("transcript"),
  log: document.getElementById("log"),
};

let ws = null;
let captureContext = null;
let playbackContext = null;
let micStream = null;
let workletNode = null;
let sourceNode = null;
let nextPlayAt = 0;
const activeSources = new Set();
let assistantLine = null;
let userLine = null;
let receivedAudioSeconds = 0;

function log(message) {
  const line = `${new Date().toLocaleTimeString()} ${message}`;
  els.log.textContent = `${line}\n${els.log.textContent}`.slice(0, 8000);
}

function setStatus(text) {
  els.status.textContent = text;
}

function refreshStatus() {
  if (!ws || ws.readyState !== WebSocket.OPEN) return;
  setStatus(`已连接 · 已接收 ${receivedAudioSeconds.toFixed(1)}s 音频`);
}

function setRunning(running) {
  els.start.disabled = running;
  els.stop.disabled = !running;
  els.interrupt.disabled = !running;
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
  return bytesToBase64(new Uint8Array(int16.buffer, int16.byteOffset, int16.byteLength));
}

function lineFor(role) {
  const key = role === "user" ? "user" : "assistant";
  if (key === "user" && userLine) return userLine;
  if (key === "assistant" && assistantLine) return assistantLine;
  const div = document.createElement("div");
  const label = document.createElement("span");
  label.className = "role";
  label.textContent = key === "user" ? "你" : "助手";
  const text = document.createElement("span");
  div.append(label, text);
  els.transcript.append(div);
  if (key === "user") userLine = text;
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
  const samples = new Int16Array(bytes.buffer, bytes.byteOffset, bytes.byteLength / 2);
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
  if (!ws || ws.readyState !== WebSocket.OPEN) return;
  ws.send(JSON.stringify(event));
}

function handleServerEvent(event) {
  switch (event.type) {
    case "session.ready":
      log(`ready session=${event.sessionId} caps=${event.capabilities.join(",")}`);
      setStatus("已连接，开始说话");
      break;
    case "transcript.partial":
      lineFor(event.role).textContent = event.text;
      break;
    case "transcript.final":
      lineFor(event.role).textContent = event.text;
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
      break;
    case "error":
      log(`error ${event.code}: ${event.message}`);
      setStatus(`错误：${event.code}`);
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

async function start() {
  setRunning(true);
  setStatus("连接中…");
  resetLines();
  els.transcript.textContent = "";
  playbackContext = new AudioContext({ sampleRate: OUTPUT_RATE });

  const url = `${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/api/realtime`;
  ws = new WebSocket(url);
  ws.onopen = async () => {
    send({
      type: "session.hello",
      requestId: `c-${Date.now()}`,
      protocolVersion: "0.2.0",
      capabilities: [
        "realtime.audio-in",
        "realtime.audio-out",
        "realtime.text-in",
        "realtime.interrupt",
        "realtime.playback-clear",
      ],
    });
    try {
      await startCapture();
      log("microphone streaming");
    } catch (error) {
      log(`microphone failed: ${error}`);
      setStatus("麦克风不可用");
      stop();
    }
  };
  ws.onmessage = (message) => {
    let event;
    try {
      event = JSON.parse(message.data);
    } catch {
      log("ignored non-JSON frame");
      return;
    }
    handleServerEvent(event);
  };
  ws.onclose = () => {
    log("socket closed");
    setStatus("已断开");
    setRunning(false);
  };
  ws.onerror = () => log("socket error");
}

function stop() {
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
    if (ws.readyState === WebSocket.OPEN) {
      send({ type: "session.close" });
    }
    ws.close();
    ws = null;
  }
  setRunning(false);
  setStatus("未连接");
}

els.start.addEventListener("click", () => {
  start().catch((error) => {
    log(`start failed: ${error}`);
    stop();
  });
});
els.stop.addEventListener("click", stop);
els.interrupt.addEventListener("click", () => {
  stopPlayback();
  send({ type: "session.interrupt" });
  log("interrupt sent");
});

// Debug hook for the headless smoke test and for manual poking in devtools.
// Not part of the gateway contract.
window.mediapilot = { send, stopPlayback };
