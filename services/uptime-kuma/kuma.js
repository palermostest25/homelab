// Kuma monitor management for PJA-14. No credentials stored: password via
// KUMA_PW_FILE (path to a file holding the password) or KUMA_PASSWORD env var.
// Password is never logged. Idempotent: reuses existing monitors.
//
// Kuma 2.x API notes (learned live against 2.0.2):
// - getMonitorList returns {ok:true} via ack and pushes the list on the
//   "monitorList" event — read the event, not the ack payload.
// - "add" needs the dashboard's minimal push shape (see basePushMonitor);
//   cloning a ping monitor's full JSON fails server-side validation.
// - The server does NOT generate a pushToken on add; set it afterwards via
//   editMonitor (same channel the dashboard uses: watcher on monitor.type
//   generates the token client-side with genSecret(32)).
// - getMonitorNotification / addMonitorNotification do not exist in 2.x;
//   pass notificationIDList: {1:true} in the add/edit payload instead.
const { io } = require("socket.io-client");
const fs = require("fs");

const HOST = process.env.KUMA_HOST || "192.168.1.10";
const PORT = process.env.KUMA_PORT || "1003";
const USER = process.env.KUMA_USER || "denby";
const PASSWORD = process.env.KUMA_PW_FILE
  ? fs.readFileSync(process.env.KUMA_PW_FILE, "utf8").trim()
  : process.env.KUMA_PASSWORD;
if (!PASSWORD) { console.error("KUMA_PW_FILE or KUMA_PASSWORD required"); process.exit(2); }

const MODE = process.argv[2] || "list"; // list | ensure-push
const NOTIFICATION_ID = 1;
const WANT = ["sentry-push-proxmox", "sentry-push-truenas", "sentry-push-arcane"];

// 32-char alphanumeric, same alphabet as the dashboard's genSecret(32).
function genPushToken() {
  const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
  let s = "";
  for (let i = 0; i < 32; i++) s += chars[Math.floor(Math.random() * chars.length)];
  return s;
}

function basePushMonitor(name) {
  return {
    name, type: "push", interval: 300, retryInterval: 300, resendInterval: 0,
    maxretries: 0, active: true, upsideDown: false, ignoreTls: false,
    expiryNotification: false,
    description: "PJA-14 sentry-push " + name.split("-").pop(),
    accepted_statuscodes: ["200-299"],
    kafkaProducerBrokers: [],
    kafkaProducerSaslOptions: { mechanism: "None" },
    conditions: [], rabbitmqNodes: [],
    notificationIDList: { [NOTIFICATION_ID]: true },
  };
}

function emitAck(socket, event, data, ms = 30000) {
  return new Promise((resolve) => {
    const t = setTimeout(() => resolve({ __timeout: true, event }), ms);
    socket.emit(event, data, (res) => { clearTimeout(t); resolve(res); });
  });
}

async function main() {
  const socket = io(`http://${HOST}:${PORT}`, { transports: ["polling"] });
  await new Promise((res, rej) => {
    socket.on("connect", res);
    socket.on("connect_error", (e) => rej(new Error("connect: " + e.message)));
    setTimeout(() => rej(new Error("connect timeout")), 20000);
  });
  let cache = null;
  socket.on("monitorList", (data) => { cache = data || {}; });
  socket.on("updateMonitorIntoList", (data) => {
    if (data && data.id && cache) cache[data.id] = Object.assign({}, cache[data.id], data);
  });
  const refresh = () => new Promise((res) => {
    socket.emit("getMonitorList", () => {});
    setTimeout(res, 3500);
  });
  const login = await emitAck(socket, "login", { username: USER, password: PASSWORD, token: "" }, 20000);
  if (!login || !login.ok) { console.error("LOGIN_FAILED"); process.exit(1); }
  console.log("LOGIN_OK");
  await refresh();
  const arr = Object.values(cache || {});
  console.log("MONITOR_COUNT " + arr.length);
  for (const m of arr) console.log(`HAVE id=${m.id} name=${m.name} type=${m.type} active=${m.active} interval=${m.interval}`);
  if (MODE === "ensure-push") {
    const byName = Object.fromEntries(arr.map((m) => [m.name, m]));
    for (const name of WANT) {
      if (byName[name]) {
        console.log(`EXISTS ${name} id=${byName[name].id}`);
        continue;
      }
      const res = await emitAck(socket, "add", basePushMonitor(name), 30000);
      // Never print pushToken material here (none exists yet at add time).
      console.log("ADD " + name + " -> " + JSON.stringify({ ok: res && res.ok, monitorID: res && res.monitorID }));
      if (!res || !res.ok) { console.error("ADD_FAILED " + name + " msg=" + (res && res.msg)); process.exit(1); }
      await new Promise((r) => setTimeout(r, 2000));
    }
    // The server stores no pushToken on add — set one per monitor via
    // editMonitor, exactly as the dashboard does when type flips to push.
    for (const name of WANT) {
      const gm = await emitAck(socket, "getMonitor",
        byName[name] ? byName[name].id : (await refresh(), Object.values(cache).find((m) => m.name === name).id),
        20000);
      if (!gm || !gm.ok) { console.error("GET_FAILED " + name); process.exit(1); }
      const m = gm.monitor;
      if (!m.pushToken) {
        m.pushToken = process.env["PUSH_TOKEN_" + name.split("-").pop().toUpperCase()] || genPushToken();
        m.notificationIDList = { [NOTIFICATION_ID]: true };
        m.includeSensitiveData = true;
        const res = await emitAck(socket, "editMonitor", m, 30000);
        console.log("TOKEN_SET " + name + " ok=" + (res && res.ok));
        if (!res || !res.ok) { console.error("TOKEN_FAILED " + name); process.exit(1); }
        await new Promise((r) => setTimeout(r, 1500));
      } else console.log("TOKEN_EXISTS " + name);
    }
    await refresh();
    for (const m of Object.values(cache || {}).filter((m) => WANT.includes(m.name))) {
      // Token value itself is never printed: it lives only in Kuma's db and
      // each host's crontab line, never in logs or the repo.
      console.log(`PUSH_URL ${m.name} id=${m.id} token_len=${(m.pushToken || "").length} url=http://${HOST}:${PORT}/api/push/<TOKEN>`);
    }
  }
  socket.disconnect();
}
main().catch((e) => { console.error("ERR " + e.message); process.exit(1); });
