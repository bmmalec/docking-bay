"use strict";

let CONFIG = null;
let PROJECTS = [];
let filterText = "";
let selectedIndex = 0;
let visibleChips = [];
let colorMap = new Map();

const LS_RECENT = "launcher.recent";
const LS_FAVS = "launcher.favorites";
const LS_CUSTOM = "launcher.custom";
const LS_SCHEME = "launcher.colorScheme";

const KIND_LABEL = {
  "ssh-devcontainer": "devcontainer",
  "ssh": "ssh folder",
  "local": "local folder",
  "wsl": "wsl",
};

function toHex(str) {
  return Array.from(new TextEncoder().encode(str)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function hashStr(s) {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
}

function hslToHex(h, s, l) {
  s /= 100; l /= 100;
  const k = (n) => (n + h / 30) % 12;
  const a = s * Math.min(l, 1 - l);
  const f = (n) => l - a * Math.max(-1, Math.min(k(n) - 3, Math.min(9 - k(n), 1)));
  const toHex2 = (x) => Math.round(255 * x).toString(16).padStart(2, "0");
  return `#${toHex2(f(0))}${toHex2(f(8))}${toHex2(f(4))}`.toUpperCase();
}

function fgForHsl(l) {
  return l > 55 ? "#151719" : "#FFFFFF";
}

function resolveProfile(id) {
  return (CONFIG.profiles || []).find((p) => p.id === id);
}

function buildUri(proj) {
  const t = proj.target;
  if (!t) return "#";
  switch (t.kind) {
    case "ssh-devcontainer": {
      const profile = resolveProfile(t.profile);
      const sshHex = toHex(JSON.stringify({ hostName: profile.sshHost, user: profile.sshUser }));
      const hostPath = t.hostPath;
      const dcJson = JSON.stringify({
        hostPath: hostPath,
        localDocker: false,
        configFile: { "$mid": 1, path: `${hostPath}/.devcontainer/devcontainer.json`, scheme: "vscode-fileHost" },
      });
      const dcHex = toHex(dcJson);
      const wsFolder = t.workspaceFolder || "/workspace";
      return `vscode://vscode-remote/dev-container%2B${dcHex}@ssh-remote%2B${sshHex}${wsFolder}?windowId=_blank`;
    }
    case "ssh": {
      const profile = resolveProfile(t.profile);
      const sshHex = toHex(JSON.stringify({ hostName: profile.sshHost, user: profile.sshUser }));
      return `vscode://vscode-remote/ssh-remote%2B${sshHex}${t.path}?windowId=_blank`;
    }
    case "local": {
      let norm = t.path.replace(/\\/g, "/").replace(/\/+$/, "") + "/";
      norm = norm.replace(/^([A-Za-z]):/, (m, d) => d.toLowerCase() + ":");
      return `vscode://file/${norm}?windowId=_blank`;
    }
    case "wsl": {
      return `vscode://vscode-remote/wsl+${encodeURIComponent(t.distro)}${t.path}?windowId=_blank`;
    }
    default:
      return "#";
  }
}

function targetPathLabel(proj) {
  const t = proj.target;
  if (!t) return proj.p;
  if (t.kind === "ssh-devcontainer") return t.hostPath;
  if (t.kind === "ssh") return t.path;
  if (t.kind === "local") return t.path;
  if (t.kind === "wsl") return `[${t.distro}] ${t.path}`;
  return proj.p;
}

// --- storage ---

function getRecent() { try { return JSON.parse(localStorage.getItem(LS_RECENT) || "[]"); } catch { return []; } }
function setRecent(arr) { localStorage.setItem(LS_RECENT, JSON.stringify(arr)); }
function getFavs() { try { return JSON.parse(localStorage.getItem(LS_FAVS) || "[]"); } catch { return []; } }
function setFavs(arr) { localStorage.setItem(LS_FAVS, JSON.stringify(arr)); }
function getCustom() { try { return JSON.parse(localStorage.getItem(LS_CUSTOM) || "[]"); } catch { return []; } }
function setCustom(arr) { localStorage.setItem(LS_CUSTOM, JSON.stringify(arr)); }
function getScheme() { return localStorage.getItem(LS_SCHEME) || "manual"; }
function setScheme(s) { localStorage.setItem(LS_SCHEME, s); }

function allProjects() {
  return PROJECTS.concat(getCustom());
}

function touchRecent(p) {
  let recent = getRecent().filter((x) => x !== p);
  recent.unshift(p);
  recent = recent.slice(0, 8);
  setRecent(recent);
}

function toggleFav(p) {
  let favs = getFavs();
  if (favs.includes(p)) favs = favs.filter((x) => x !== p);
  else favs.unshift(p);
  setFavs(favs);
}

function matchesFilter(proj, q) {
  if (!q) return true;
  return proj.t.toLowerCase().includes(q) || proj.p.toLowerCase().includes(q);
}

// --- color schemes ---

const PALETTE = [
  ["#3B82F6", "#FFFFFF"], ["#8B5CF6", "#FFFFFF"], ["#EA580C", "#FFFFFF"], ["#16A34A", "#FFFFFF"],
  ["#0D9488", "#FFFFFF"], ["#EC4899", "#FFFFFF"], ["#DC2626", "#FFFFFF"], ["#B45309", "#FFFFFF"],
  ["#0EA5E9", "#FFFFFF"], ["#D946EF", "#FFFFFF"], ["#EAB308", "#422006"], ["#84CC16", "#1A2E05"],
  ["#F43F5E", "#FFFFFF"], ["#64748B", "#FFFFFF"],
];

const KIND_HUE = {
  "local": [220, 10, 45],
  "ssh": [210, 55, 42],
  "ssh-devcontainer": [165, 55, 38],
  "wsl": [265, 50, 45],
};

function stemOf(p) {
  const suffix = /(_?-?(public|pub|app|care|agents|agent|synth|demo|test|tests|legacy|core|strategy|v\d+|\d+))$/i;
  let s = p;
  let changed = true;
  while (changed) {
    changed = false;
    const m = s.match(suffix);
    if (m && s.length > m[0].length) {
      s = s.slice(0, s.length - m[0].length);
      changed = true;
    }
  }
  s = s.replace(/[_\-.]+$/, "");
  return s || p;
}

function computeColorMap(scheme, all) {
  const map = new Map();

  if (scheme === "hash-palette") {
    all.forEach((p) => {
      const [bg, fg] = PALETTE[hashStr(p.p) % PALETTE.length];
      map.set(p.p, { bg, fg });
    });
    return map;
  }

  if (scheme === "family") {
    const groups = new Map();
    all.forEach((p) => {
      const stem = stemOf(p.p);
      if (!groups.has(stem)) groups.set(stem, []);
      groups.get(stem).push(p.p);
    });
    all.forEach((p) => {
      const stem = stemOf(p.p);
      const idx = groups.get(stem).indexOf(p.p);
      const hue = hashStr(stem) % 360;
      const light = Math.min(38 + idx * 8, 72);
      map.set(p.p, { bg: hslToHex(hue, 55, light), fg: fgForHsl(light) });
    });
    return map;
  }

  if (scheme === "kind") {
    all.forEach((p) => {
      const kind = p.target ? p.target.kind : "local";
      const [h, s, baseL] = KIND_HUE[kind] || KIND_HUE.local;
      const l = Math.max(22, Math.min(68, baseL + (hashStr(p.p) % 17) - 8));
      map.set(p.p, { bg: hslToHex(h, s, l), fg: fgForHsl(l) });
    });
    return map;
  }

  if (scheme === "rainbow") {
    const sorted = [...all].sort((a, b) => a.p.localeCompare(b.p));
    sorted.forEach((p, i) => {
      const hue = sorted.length > 1 ? (i / (sorted.length - 1)) * 300 : 0;
      map.set(p.p, { bg: hslToHex(hue, 55, 42), fg: fgForHsl(42) });
    });
    return map;
  }

  // manual (default): use stored colors as-is
  all.forEach((p) => map.set(p.p, { bg: p.bg, fg: p.fg }));
  return map;
}

// --- rendering ---

function makeChip(proj) {
  const uri = buildUri(proj);
  const a = document.createElement("a");
  a.className = "chip";
  if (proj._missing) a.classList.add("missing");
  else if (proj._review) a.classList.add("review");

  const colors = colorMap.get(proj.p) || { bg: proj.bg, fg: proj.fg };

  a.href = uri;
  a.style.color = colors.fg;
  a.dataset.p = proj.p;

  const favs = getFavs();
  const isFav = favs.includes(proj.p);

  const titlebar = document.createElement("div");
  titlebar.className = "titlebar";
  titlebar.style.background = colors.bg;
  titlebar.style.color = colors.fg;

  const emoji = document.createElement("span");
  emoji.className = "emoji";
  emoji.textContent = proj.e;

  const name = document.createElement("span");
  name.className = "name";
  name.textContent = proj.t;

  const starBtn = document.createElement("button");
  starBtn.type = "button";
  starBtn.className = "star-btn" + (isFav ? " on" : "");
  starBtn.title = "Toggle favorite";
  starBtn.textContent = "★";

  titlebar.append(emoji, name, starBtn);

  const meta = document.createElement("div");
  meta.className = "chipmeta";

  const path = document.createElement("span");
  path.className = "path";
  path.textContent = targetPathLabel(proj);

  const kind = document.createElement("span");
  kind.className = "kind";
  let kindText = (proj.target && KIND_LABEL[proj.target.kind]) || "unknown";
  if (proj._missing) kindText += " · missing";
  else if (proj._review) kindText += " · new, review";
  else if (proj._custom) kindText += " · custom";
  kind.textContent = kindText;

  const rightWrap = document.createElement("span");
  rightWrap.className = "meta-right";
  rightWrap.append(kind);

  if (proj._custom) {
    const delBtn = document.createElement("button");
    delBtn.type = "button";
    delBtn.className = "delete-btn";
    delBtn.title = "Delete this project";
    delBtn.textContent = "✕";
    delBtn.addEventListener("click", (ev) => {
      ev.preventDefault();
      ev.stopPropagation();
      if (confirm(`Delete "${proj.t}"?`)) {
        setCustom(getCustom().filter((c) => c.p !== proj.p));
        render();
      }
    });
    rightWrap.append(delBtn);
  }

  meta.append(path, rightWrap);
  a.append(titlebar, meta);

  a.addEventListener("click", () => {
    touchRecent(proj.p);
    setTimeout(render, 0);
  });

  starBtn.addEventListener("click", (ev) => {
    ev.preventDefault();
    ev.stopPropagation();
    toggleFav(proj.p);
    render();
  });

  return a;
}

function fillGrid(gridEl, projects) {
  gridEl.innerHTML = "";
  const chips = projects.map(makeChip);
  chips.forEach((chip) => gridEl.appendChild(chip));
  return chips;
}

function render() {
  const q = filterText.trim().toLowerCase();
  const all = allProjects();
  colorMap = computeColorMap(getScheme(), all);

  const byPath = Object.fromEntries(all.map((p) => [p.p, p]));

  const recentAll = getRecent().map((p) => byPath[p]).filter(Boolean);
  const favsAll = getFavs().map((p) => byPath[p]).filter(Boolean);

  const recent = recentAll.filter((p) => matchesFilter(p, q));
  const favs = favsAll.filter((p) => matchesFilter(p, q));
  const visible = all.filter((p) => matchesFilter(p, q));

  const recentSection = document.getElementById("recent-section");
  const recentGrid = document.getElementById("recent-grid");
  let recentChips = [];
  if (recent.length) {
    recentSection.style.display = "";
    recentChips = fillGrid(recentGrid, recent);
  } else {
    recentSection.style.display = "none";
    recentGrid.innerHTML = "";
  }

  const favSection = document.getElementById("favorites-section");
  const favGrid = document.getElementById("favorites-grid");
  let favChips = [];
  if (favs.length) {
    favSection.style.display = "";
    favChips = fillGrid(favGrid, favs);
  } else {
    favSection.style.display = "none";
    favGrid.innerHTML = "";
  }

  const allGrid = document.getElementById("all-grid");
  const allChips = fillGrid(allGrid, visible);

  const noResults = document.getElementById("no-results");
  const totalVisible = recent.length + favs.length + visible.length;
  if (q && totalVisible === 0) {
    noResults.style.display = "";
    document.getElementById("no-results-query").textContent = filterText.trim();
  } else {
    noResults.style.display = "none";
  }

  visibleChips = [...recentChips, ...favChips, ...allChips];
  selectedIndex = 0;
  highlightSelected();
}

function highlightSelected() {
  visibleChips.forEach((el, i) => el.classList.toggle("selected", i === selectedIndex));
  if (visibleChips[selectedIndex]) {
    visibleChips[selectedIndex].scrollIntoView({ block: "nearest" });
  }
}

function moveSelection(dir) {
  if (!visibleChips.length) return;
  if (dir === "right") {
    selectedIndex = Math.min(selectedIndex + 1, visibleChips.length - 1);
  } else if (dir === "left") {
    selectedIndex = Math.max(selectedIndex - 1, 0);
  } else if (dir === "down" || dir === "up") {
    const curRect = visibleChips[selectedIndex].getBoundingClientRect();
    let best = -1;
    let bestDist = Infinity;
    visibleChips.forEach((el, i) => {
      if (i === selectedIndex) return;
      const r = el.getBoundingClientRect();
      const inDirection = dir === "down" ? r.top > curRect.top + 4 : r.top < curRect.top - 4;
      if (!inDirection) return;
      const dy = Math.abs(r.top - curRect.top);
      const dx = Math.abs((r.left + r.width / 2) - (curRect.left + curRect.width / 2));
      const dist = dy * 1000 + dx;
      if (dist < bestDist) { bestDist = dist; best = i; }
    });
    if (best !== -1) selectedIndex = best;
  }
  highlightSelected();
}

function showLoadError(detail) {
  const el = document.getElementById("load-error");
  el.style.display = "";
  el.textContent =
    `Couldn't load launcher.config.json / projects.json (${detail}).\n\n` +
    `This usually means the page was opened directly from disk (file://), which browsers block from fetching local JSON files.\n` +
    `Run scripts/serve-launcher.ps1 and open the http://localhost URL it prints instead.`;
}

function setupHelpDialog() {
  const dialog = document.getElementById("help-dialog");
  document.getElementById("help-btn").addEventListener("click", () => dialog.showModal());
  document.getElementById("help-close").addEventListener("click", () => dialog.close());
}

// --- add-project dialog ---

function fillSelect(selectEl, items, valueKey, labelKey) {
  selectEl.innerHTML = "";
  items.forEach((item) => {
    const opt = document.createElement("option");
    opt.value = item[valueKey];
    opt.textContent = item[labelKey];
    selectEl.appendChild(opt);
  });
}

function showFormError(msg) {
  const el = document.getElementById("f-error");
  el.textContent = msg;
  el.hidden = false;
}

function setupAddDialog() {
  const dialog = document.getElementById("add-dialog");
  const form = document.getElementById("add-form");
  const addBtn = document.getElementById("add-btn");
  const cancelBtn = document.getElementById("f-cancel");
  const kindSelect = document.getElementById("f-kind");
  const errorEl = document.getElementById("f-error");

  const fieldGroups = {
    local: document.getElementById("fields-local"),
    ssh: document.getElementById("fields-ssh"),
    "ssh-devcontainer": document.getElementById("fields-ssh-devcontainer"),
    wsl: document.getElementById("fields-wsl"),
  };

  const profiles = CONFIG.profiles || [];
  fillSelect(document.getElementById("f-ssh-profile"), profiles, "id", "label");
  fillSelect(document.getElementById("f-dc-profile"), profiles, "id", "label");

  function showKindFields(kind) {
    Object.entries(fieldGroups).forEach(([k, el]) => { el.hidden = k !== kind; });
  }

  kindSelect.addEventListener("change", () => showKindFields(kindSelect.value));

  addBtn.addEventListener("click", () => {
    form.reset();
    errorEl.hidden = true;
    showKindFields(kindSelect.value);
    dialog.showModal();
    document.getElementById("f-title").focus();
  });

  cancelBtn.addEventListener("click", () => dialog.close());

  form.addEventListener("submit", (e) => {
    e.preventDefault();
    errorEl.hidden = true;

    const id = document.getElementById("f-id").value.trim();
    const title = document.getElementById("f-title").value.trim();
    const emoji = document.getElementById("f-emoji").value.trim() || "⚪";
    const kind = kindSelect.value;
    const bg = document.getElementById("f-bg").value;
    const fg = document.getElementById("f-fg").value;

    if (!id || !title) return showFormError("Title and Folder/ID are required.");
    const existingIds = new Set(allProjects().map((p) => p.p));
    if (existingIds.has(id)) return showFormError(`"${id}" already exists.`);

    let target;
    if (kind === "local") {
      const path = document.getElementById("f-local-path").value.trim();
      if (!path) return showFormError("Path is required.");
      target = { kind: "local", path };
    } else if (kind === "ssh") {
      const profile = document.getElementById("f-ssh-profile").value;
      const path = document.getElementById("f-ssh-path").value.trim();
      if (!profile || !path) return showFormError("Profile and path are required.");
      target = { kind: "ssh", profile, path };
    } else if (kind === "ssh-devcontainer") {
      const profile = document.getElementById("f-dc-profile").value;
      const hostPath = document.getElementById("f-dc-hostpath").value.trim();
      const workspaceFolder = document.getElementById("f-dc-wsfolder").value.trim() || "/workspace";
      if (!profile || !hostPath) return showFormError("Profile and host path are required.");
      target = { kind: "ssh-devcontainer", profile, hostPath, workspaceFolder };
    } else if (kind === "wsl") {
      const distro = document.getElementById("f-wsl-distro").value.trim();
      const path = document.getElementById("f-wsl-path").value.trim();
      if (!distro || !path) return showFormError("Distro and path are required.");
      target = { kind: "wsl", distro, path };
    }

    const custom = getCustom();
    custom.push({ p: id, t: title, e: emoji, bg, fg, target, _custom: true });
    setCustom(custom);
    dialog.close();
    render();
  });
}

async function boot() {
  document.getElementById("reset-recent").addEventListener("click", () => {
    if (confirm("Clear the Recent list?")) { setRecent([]); render(); }
  });
  document.getElementById("reset-favorites").addEventListener("click", () => {
    if (confirm("Clear all Favorites?")) { setFavs([]); render(); }
  });

  const search = document.getElementById("search");
  search.addEventListener("input", () => {
    filterText = search.value;
    render();
  });
  search.addEventListener("keydown", (e) => {
    switch (e.key) {
      case "ArrowDown": e.preventDefault(); moveSelection("down"); break;
      case "ArrowUp": e.preventDefault(); moveSelection("up"); break;
      case "ArrowRight": e.preventDefault(); moveSelection("right"); break;
      case "ArrowLeft": e.preventDefault(); moveSelection("left"); break;
      case "Enter": {
        e.preventDefault();
        const chip = visibleChips[selectedIndex];
        if (chip) chip.click();
        break;
      }
      case "Escape":
        search.value = "";
        filterText = "";
        render();
        break;
    }
  });

  const schemeSelect = document.getElementById("color-scheme");
  schemeSelect.addEventListener("change", () => {
    setScheme(schemeSelect.value);
    render();
  });

  let cfg, projects;
  try {
    [cfg, projects] = await Promise.all([
      fetch("./launcher.config.json").then((r) => { if (!r.ok) throw new Error(`HTTP ${r.status}`); return r.json(); }),
      fetch("./projects.json").then((r) => { if (!r.ok) throw new Error(`HTTP ${r.status}`); return r.json(); }),
    ]);
  } catch (err) {
    showLoadError(err.message || String(err));
    return;
  }

  CONFIG = cfg;
  PROJECTS = projects;

  const profileLabels = (CONFIG.profiles || []).map((p) => p.label).join(", ") || "no profiles configured";
  document.getElementById("eyebrow").textContent = profileLabels;

  schemeSelect.value = getScheme();
  setupAddDialog();
  setupHelpDialog();

  render();
  search.focus();

  if ("serviceWorker" in navigator) {
    navigator.serviceWorker.register("./launcher-sw.js").catch(() => {});
  }
}

boot();
