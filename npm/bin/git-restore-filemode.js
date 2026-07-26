#!/usr/bin/env node

const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const installer = require("../install");

const executable = installer.binaryPath();

if (!fs.existsSync(executable)) {
  const result = spawnSync(process.execPath, [path.join(__dirname, "..", "install.js")], {
    stdio: "inherit"
  });
  if (result.error) {
    throw result.error;
  }
  process.exitCode = result.status ?? 1;
  if (process.exitCode !== 0) {
    process.exit();
  }
}

const result = spawnSync(executable, process.argv.slice(2), { stdio: "inherit" });
if (result.error) {
  throw result.error;
}

process.exit(result.status ?? 1);
