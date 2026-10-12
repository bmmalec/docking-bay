"use strict";
// Node port of scripts/refresh-projects.ps1: scans every location under "scans"
// in launcher.config.js and merges what it finds into projects.js. Keep the two
// in step — same scan kinds, same non-destructive merge, same scan-status.js.

const fs = require("fs");
const path = require("path");
const { execFile } = require("child_process");
const { readDataFile, writeDataFile } = require("./data");

const ROOT = path.resolve(__dirname, "..");
const CONFIG_FILE = path.join(ROOT, "launcher.config.js");
const PROJECTS_FILE = path.join(ROOT, "projects.js");
const STATUS_FILE = path.join(ROOT, "scan-status.js");
const TIMEOUT_MS = 60000;

// One fixed, read-only script (scan-remote.sh), fed to bash over stdin. The scan
// path arrives as $1 and is never interpolated into the script text, and
// directory names found on the remote are only ever treated as data.
const REMOTE_SCRIPT = fs.readFileSync(path.join(__dirname, "scan-remote.sh"), "utf8").replace(/\r/g, "");

function runBash(exe, args) {
  return new Promise((resolve, reject) => {
    const child = execFile(exe, args, { timeout: TIMEOUT_MS, maxBuffer: 16 * 1024 * 1024, windowsHide: true },
      (err, stdout, stderr) => {
        if (err) {
          if (err.killed) return reject(new Error(`timed out after ${TIMEOUT_MS / 1000}s`));
          return reject(new Error(`exit ${err.code}: ${String(stderr || err.message).trim()}`));
        }
        const found = [];
        for (const line of stdout.split("\n")) {
          const f = line.replace(/\r$/, "").split("\x1f");
          if (f.length < 6) continue;
          found.push({ name: f[0], hasDc: f[1] === "1", wsFolder: f[2], bg: f[4], fg: f[5] });
        }
        resolve(found);
      });
    child.stdin.on("error", () => { /* surfaced through the exit code */ });
    child.stdin.end(REMOTE_SCRIPT);
  });
}

function jsonString(file, key) {
  try {
    const m = new RegExp(`"${key.replace(/\./g, "\\.")}"\\s*:\\s*"([^"]*)"`).exec(fs.readFileSync(file, "utf8"));
    return m ? m[1] : "";
  } catch { return ""; }
}

async function scanLocal(dir) {
  let entries;
  try { entries = await fs.promises.readdir(dir, { withFileTypes: true }); }
  catch { throw new Error(`no such directory: ${dir}`); }
  return entries.filter((e) => e.isDirectory()).map((e) => {
    const full = path.join(dir, e.name);
    const settings = path.join(full, ".vscode", "settings.json");
    return {
      name: e.name,
      hasDc: fs.existsSync(path.join(full, ".devcontainer", "devcontainer.json")),
      wsFolder: "",
      bg: jsonString(settings, "titleBar.activeBackground"),
      fg: jsonString(settings, "titleBar.activeForeground"),
    };
  });
}

function invokeScan(scan) {
  switch (scan.kind) {
    case "ssh": {
      // ssh joins its trailing args into one string for the remote shell, so the
      // path is single-quoted to survive spaces and metacharacters. BatchMode:
      // fail instead of waiting on a prompt nothing could answer.
      const quoted = `'${scan.path.replace(/'/g, `'\\''`)}'`;
      return runBash("ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", scan.sshTarget, "bash", "-s", "--", quoted]);
    }
    case "wsl":
      return runBash("wsl.exe", ["-d", scan.distro, "--exec", "bash", "-s", "--", scan.path]);
    default:
      return scanLocal(scan.path);
  }
}

// Comparable form of a folder path: local (Windows) paths are case-insensitive
// and may use either slash; remote paths are compared exactly.
function pathKey(source, p) {
  let n = p.replace(/\\/g, "/");
  if (n.length > 1) n = n.replace(/\/+$/, "");
  return source === "local" ? n.toLowerCase() : n;
}

function parentKey(key) {
  const i = key.lastIndexOf("/");
  return i <= 0 ? "/" : key.slice(0, i);
}

function targetLocation(t) {
  if (!t) return null;
  let source = null, p = null;
  switch (t.kind) {
    case "ssh-devcontainer": source = `ssh|${t.profile}`; p = t.hostPath; break;
    case "ssh": source = `ssh|${t.profile}`; p = t.path; break;
    case "wsl": source = `wsl|${t.distro}`; p = t.path; break;
    case "local": source = "local"; p = t.path; break;
  }
  if (!source || !p) return null;
  const k = pathKey(source, p);
  return { source, pathKey: k, key: `${source}|${k}` };
}

function getScans(config) {
  const profiles = new Map((config.profiles || []).filter((p) => p && p.id).map((p) => [p.id, p]));
  const entries = (config.scans || []).filter(Boolean).map((s) => ({ ...s }));
  for (const p of config.profiles || []) {
    if (p && p.basePath) entries.push({ kind: "ssh", profile: p.id, path: p.basePath });
  }

  const seen = new Set();
  const scans = [];
  for (const e of entries) {
    let scan;
    switch (e.kind) {
      case "ssh": {
        const prof = profiles.get(String(e.profile));
        if (!prof) throw new Error(`scan refers to unknown profile '${e.profile}'`);
        const sshTarget = `${prof.sshUser}@${prof.sshHost}`;
        if (sshTarget.startsWith("-")) throw new Error(`profile '${prof.id}' has an invalid ssh user/host`);
        scan = { kind: "ssh", source: `ssh|${prof.id}`, idSuffix: prof.id, profile: prof.id, sshTarget, label: `${prof.id}:${e.path}` };
        break;
      }
      case "wsl":
        if (!e.distro) throw new Error("wsl scan needs a 'distro'");
        scan = { kind: "wsl", source: `wsl|${e.distro}`, idSuffix: e.distro, distro: e.distro, label: `wsl ${e.distro}:${e.path}` };
        break;
      case "local":
        scan = { kind: "local", source: "local", idSuffix: "local", label: `local:${e.path}` };
        break;
      default:
        throw new Error(`unknown scan kind '${e.kind}' (expected ssh, wsl or local)`);
    }
    if (!e.path) throw new Error(`${e.kind} scan needs a 'path'`);
    scan.path = String(e.path);
    scan.rootKey = `${scan.source}|${pathKey(scan.source, scan.path)}`;
    if (!seen.has(scan.rootKey)) { seen.add(scan.rootKey); scans.push(scan); }
  }
  return scans;
}

function newTarget(scan, fullPath, found) {
  switch (scan.kind) {
    case "ssh":
      return found.hasDc
        ? { kind: "ssh-devcontainer", profile: scan.profile, hostPath: fullPath, workspaceFolder: found.wsFolder || "/workspace" }
        : { kind: "ssh", profile: scan.profile, path: fullPath };
    case "wsl": return { kind: "wsl", distro: scan.distro, path: fullPath };
    default: return { kind: "local", path: fullPath };
  }
}

async function runScan(log = () => {}) {
  const status = { at: new Date().toISOString(), scans: [], added: [], missing: [], colorChanged: [] };
  try {
    const config = readDataFile(CONFIG_FILE, "DOCKING_BAY_CONFIG");
    const projects = readDataFile(PROJECTS_FILE, "DOCKING_BAY_PROJECTS");
    const before = JSON.stringify(projects);
    const scans = getScans(config);

    const byKey = new Map();
    const usedIds = new Set();
    for (const p of projects) {
      usedIds.add(String(p.p));
      const loc = targetLocation(p.target);
      if (loc) byKey.set(loc.key, p);
    }

    const seenByRoot = new Map();
    for (const scan of scans) {
      log(`Scanning ${scan.label} ...`);
      let found;
      try {
        found = await invokeScan(scan);
      } catch (err) {
        // One unreachable location must not block the others, and its projects
        // are left exactly as they were (not flagged missing).
        log(`  failed: ${err.message}`);
        status.scans.push({ label: scan.label, ok: false, found: 0, error: String(err.message) });
        continue;
      }
      status.scans.push({ label: scan.label, ok: true, found: found.length, error: null });

      const seen = new Set();
      seenByRoot.set(scan.rootKey, seen);
      const displayBase = scan.path.replace(/\\/g, "/").replace(/\/+$/, "");

      for (const f of found) {
        const fullPath = `${displayBase}/${f.name}`;
        const key = `${scan.source}|${pathKey(scan.source, fullPath)}`;
        seen.add(key);

        const proj = byKey.get(key);
        if (proj) {
          if (scan.kind === "ssh" && f.hasDc) {
            if (proj.target.kind !== "ssh-devcontainer") proj.target = newTarget(scan, fullPath, f);
            else if (f.wsFolder && proj.target.workspaceFolder !== f.wsFolder) proj.target.workspaceFolder = f.wsFolder;
          }
          if (f.bg && proj.bg !== f.bg) { status.colorChanged.push(`${proj.p} (bg ${proj.bg} -> ${f.bg})`); proj.bg = f.bg; }
          if (f.fg && proj.fg !== f.fg) { status.colorChanged.push(`${proj.p} (fg ${proj.fg} -> ${f.fg})`); proj.fg = f.fg; }
          delete proj._missing;
        } else {
          // "p" is the tile's unique id; the same folder name under two scan
          // locations gets the source appended.
          let id = f.name;
          if (usedIds.has(id)) {
            const base = `${f.name}@${scan.idSuffix}`;
            id = base;
            for (let n = 2; usedIds.has(id); n++) id = `${base}-${n}`;
          }
          usedIds.add(id);
          const created = {
            p: id,
            t: f.name,
            e: "⚪",
            bg: f.bg || "#4B5563",
            fg: f.fg || "#F9FAFB",
            target: newTarget(scan, fullPath, f),
            _review: true,
          };
          projects.push(created);
          byKey.set(key, created);
          status.added.push(id);
        }
      }
    }

    // Missing only if the folder it sits in was scanned successfully this run
    // and it wasn't there. Anything outside the scanned folders is never touched.
    for (const p of projects) {
      const loc = targetLocation(p.target);
      if (!loc) continue;
      const seen = seenByRoot.get(`${loc.source}|${parentKey(loc.pathKey)}`);
      if (!seen) continue;
      if (!seen.has(loc.key)) { p._missing = true; status.missing.push(p.p); }
    }

    // Only rewrite projects.js when something changed, so hand formatting survives.
    if (JSON.stringify(projects) !== before) writeDataFile(PROJECTS_FILE, "DOCKING_BAY_PROJECTS", projects);
  } catch (err) {
    status.fatal = String(err.message);
    status.scans = []; status.added = []; status.missing = []; status.colorChanged = [];
    log(`Scan failed: ${status.fatal}`);
  }
  writeDataFile(STATUS_FILE, "DOCKING_BAY_SCAN", status);
  return status;
}

module.exports = { runScan };
