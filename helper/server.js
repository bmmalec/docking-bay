#!/usr/bin/env node
"use strict";
// Docking Bay helper: a tiny, dependency-free local service that runs the same
// project scan as scripts/refresh-projects.ps1, so the page's Rescan button
// works without a custom URL protocol or a PowerShell process spawned by the
// browser.
//
//   node helper/server.js                run the service (scans once at start)
//   node helper/server.js --every 60     ...and rescan every 60 minutes
//   node helper/server.js --once         scan once, print the result, exit
//
// It listens on 127.0.0.1 only and exposes two things: GET /status and
// POST /rescan. /rescan takes no input; it runs the fixed scan and nothing else.

const http = require("http");
const { runScan } = require("./scan");

const HOST = "127.0.0.1";
const PORT = 47613; // keep in step with HELPER_URL in project-launcher.js and the CSP in project-launcher.html

const args = process.argv.slice(2);
const log = (msg) => console.log(`[${new Date().toLocaleTimeString()}] ${msg}`);

function summarize(s) {
  if (s.fatal) return `failed: ${s.fatal}`;
  const failed = s.scans.filter((x) => !x.ok).length;
  return `${s.scans.length - failed} of ${s.scans.length} locations, ${s.added.length} new, ${s.missing.length} missing` +
    (failed ? `, ${failed} failed` : "");
}

let running = null;
function scanOnce() {
  if (!running) {
    running = runScan(log).then((s) => { log(`Done: ${summarize(s)}`); return s; }).finally(() => { running = null; });
  }
  return running;
}

if (args.includes("--once")) {
  runScan(log).then((s) => { console.log(`Done: ${summarize(s)}`); process.exit(s.fatal ? 1 : 0); });
  return;
}

const everyIdx = args.indexOf("--every");
const everyMin = everyIdx >= 0 ? Number(args[everyIdx + 1]) : 0;
if (everyIdx >= 0 && !(everyMin >= 1)) { console.error("--every needs a number of minutes (1 or more)"); process.exit(2); }

const allowedHosts = new Set([`${HOST}:${PORT}`, `localhost:${PORT}`]);

const server = http.createServer((req, res) => {
  const send = (code, body) => {
    res.writeHead(code, { "Content-Type": "application/json", "Cache-Control": "no-store" });
    res.end(JSON.stringify(body));
  };

  // A page opened from disk sends "Origin: null"; a request with no Origin is a
  // plain tool like curl. Anything else is some website trying its luck, and a
  // foreign Host header is DNS rebinding.
  const origin = req.headers.origin;
  if (!allowedHosts.has(req.headers.host)) return send(403, { error: "bad host" });
  if (origin !== undefined && origin !== "null") return send(403, { error: "bad origin" });
  if (origin !== undefined) {
    res.setHeader("Access-Control-Allow-Origin", "null");
    res.setHeader("Access-Control-Allow-Headers", "X-Docking-Bay");
    res.setHeader("Access-Control-Allow-Methods", "GET, POST");
    res.setHeader("Access-Control-Allow-Private-Network", "true");
    res.setHeader("Vary", "Origin");
  }

  if (req.method === "OPTIONS") { res.writeHead(204); return res.end(); }
  if (req.method === "GET" && req.url === "/status") return send(200, { ok: true, scanning: !!running });
  if (req.method === "POST" && req.url === "/rescan") {
    // Custom header: a cross-site form post can't set it, and a cross-site
    // fetch with it needs the preflight above, which only allows "null".
    if (req.headers["x-docking-bay"] !== "1") return send(400, { error: "missing X-Docking-Bay header" });
    const alreadyRunning = !!running;
    scanOnce();
    return send(202, { started: !alreadyRunning });
  }
  send(404, { error: "not found" });
});

server.on("error", (err) => {
  if (err.code === "EADDRINUSE") {
    console.error(`Port ${PORT} is already in use. Is the Docking Bay helper already running?`);
  } else {
    console.error(err.message);
  }
  process.exit(1);
});

server.listen(PORT, HOST, () => {
  log(`Docking Bay helper listening on http://${HOST}:${PORT}`);
  scanOnce();
  if (everyMin) setInterval(scanOnce, everyMin * 60000).unref();
});
