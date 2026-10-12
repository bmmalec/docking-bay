"use strict";
// Reads/writes the launcher's data files: JSON wrapped in one assignment,
// `window.DOCKING_BAY_X = <json>;`, so the page can load them with a plain
// <script> tag from disk. Mirrors scripts/launcher-data.ps1.

const fs = require("fs");

function readDataFile(file, varName) {
  const raw = fs.readFileSync(file, "utf8");
  const m = new RegExp(`window\\.${varName}\\s*=`).exec(raw);
  if (!m) throw new Error(`${file} must start with 'window.${varName} = '`);
  let body = raw.slice(m.index + m[0].length).trim();
  if (body.endsWith(";")) body = body.slice(0, -1);
  return JSON.parse(body);
}

function writeDataFile(file, varName, value) {
  // Write-then-rename so the page never loads a half-written file.
  const tmp = `${file}.tmp`;
  fs.writeFileSync(tmp, `window.${varName} = ${JSON.stringify(value, null, 2)};\n`, "utf8");
  fs.renameSync(tmp, file);
}

module.exports = { readDataFile, writeDataFile };
