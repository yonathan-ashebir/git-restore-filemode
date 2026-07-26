#!/usr/bin/env node

const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const https = require("node:https");
const os = require("node:os");
const path = require("node:path");

const packageJson = require("../package.json");

const BINARY_NAME = "git-restore-filemode";
const REPO_OWNER = process.env.GIT_RESTORE_FILEMODE_REPO_OWNER || "yonathan-ashebir";
const REPO_NAME = process.env.GIT_RESTORE_FILEMODE_REPO_NAME || "git-restore-filemode";
const REPO_URL = `https://github.com/${REPO_OWNER}/${REPO_NAME}`;

function detectTarget() {
  const archMap = {
    x64: "x86_64",
    arm64: "aarch64"
  };
  const arch = archMap[process.arch];

  if (!arch) {
    throw new Error(`unsupported CPU architecture: ${process.arch}`);
  }

  if (process.platform === "linux") {
    return `${arch}-unknown-linux`;
  }
  if (process.platform === "darwin") {
    return `${arch}-apple-darwin`;
  }
  if (process.platform === "win32") {
    return `${arch}-pc-windows-msvc`;
  }

  throw new Error(`unsupported operating system: ${process.platform}`);
}

function releaseVersion() {
  return process.env.GIT_RESTORE_FILEMODE_VERSION || `v${packageJson.version}`;
}

function executableName(target) {
  return target.includes("windows") || target.includes("-pc-")
    ? `${BINARY_NAME}.exe`
    : BINARY_NAME;
}

function rustTargetForPlatform(target) {
  if (target === "x86_64-unknown-linux") {
    return "x86_64-unknown-linux-musl";
  }
  if (target === "aarch64-unknown-linux") {
    return "aarch64-unknown-linux-musl";
  }
  return target;
}

function binaryPath(target = process.env.GIT_RESTORE_FILEMODE_TARGET || detectTarget()) {
  return path.join(__dirname, "bin", "native", target, executableName(target));
}

function releaseAssetUrl(release, target) {
  const asset = `${BINARY_NAME}-${target}.tar.gz`;
  if (release === "latest") {
    return `${REPO_URL}/releases/latest/download/${asset}`;
  }
  return `${REPO_URL}/releases/download/${release}/${asset}`;
}

function download(url, destination, redirects = 0) {
  return new Promise((resolve, reject) => {
    const headers = {};
    if (process.env.GITHUB_TOKEN) {
      headers.Authorization = `Bearer ${process.env.GITHUB_TOKEN}`;
    }

    const request = https.get(url, { headers }, (response) => {
      if (
        response.statusCode >= 300 &&
        response.statusCode < 400 &&
        response.headers.location &&
        redirects < 5
      ) {
        response.resume();
        download(response.headers.location, destination, redirects + 1)
          .then(resolve)
          .catch(reject);
        return;
      }

      if (response.statusCode !== 200) {
        response.resume();
        reject(new Error(`download failed with HTTP ${response.statusCode}`));
        return;
      }

      const file = fs.createWriteStream(destination);
      response.pipe(file);
      file.on("finish", () => {
        file.close(resolve);
      });
      file.on("error", reject);
    });

    request.on("error", reject);
  });
}

function findBinary(root) {
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    const fullPath = path.join(root, entry.name);
    if (entry.isDirectory()) {
      const found = findBinary(fullPath);
      if (found) {
        return found;
      }
    } else if (entry.name === BINARY_NAME || entry.name === `${BINARY_NAME}.exe`) {
      return fullPath;
    }
  }

  return null;
}

async function installFromRelease(destination, release, target) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), `${BINARY_NAME}-`));
  const archive = path.join(tmp, `${BINARY_NAME}-${target}.tar.gz`);

  try {
    await download(releaseAssetUrl(release, target), archive);

    const extract = spawnSync("tar", ["-xzf", archive, "-C", tmp], { stdio: "inherit" });
    if (extract.status !== 0) {
      return false;
    }

    const source = findBinary(tmp);
    if (!source) {
      return false;
    }

    fs.copyFileSync(source, destination);
    fs.chmodSync(destination, 0o755);
    return true;
  } catch {
    return false;
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

function installFromCargo(destination, release, target) {
  const hasCargo = spawnSync("cargo", ["--version"], { stdio: "ignore" }).status === 0;
  const hasRustc = spawnSync("rustc", ["--version"], { stdio: "ignore" }).status === 0;
  if (!hasCargo || !hasRustc) {
    throw new Error("no matching release asset was available, and Rust/Cargo was not found");
  }

  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), `${BINARY_NAME}-cargo-`));
  const cargoRoot = path.join(tmp, "cargo-root");
  const rustTarget = rustTargetForPlatform(target);
  const hasRustup = spawnSync("rustup", ["--version"], { stdio: "ignore" }).status === 0;
  if (hasRustup) {
    const addTarget = spawnSync("rustup", ["target", "add", rustTarget], { stdio: "inherit" });
    if (addTarget.status !== 0) {
      fs.rmSync(tmp, { recursive: true, force: true });
      process.exit(addTarget.status ?? 1);
    }
  }

  const args = [
    "install",
    "--locked",
    "--git",
    REPO_URL,
    "--target",
    rustTarget,
    "--bin",
    BINARY_NAME,
    "--root",
    cargoRoot
  ];

  if (release !== "latest") {
    args.splice(4, 0, "--tag", release);
  }

  const install = spawnSync("cargo", args, { stdio: "inherit" });
  if (install.status !== 0) {
    fs.rmSync(tmp, { recursive: true, force: true });
    process.exit(install.status ?? 1);
  }

  let built = path.join(cargoRoot, "bin", executableName(target));
  if (!fs.existsSync(built)) {
    built = path.join(cargoRoot, "bin", rustTarget, executableName(target));
  }
  fs.copyFileSync(built, destination);
  fs.chmodSync(destination, 0o755);
  fs.rmSync(tmp, { recursive: true, force: true });
}

async function main() {
  const target = process.env.GIT_RESTORE_FILEMODE_TARGET || detectTarget();
  const release = releaseVersion();
  const destination = binaryPath(target);

  if (fs.existsSync(destination)) {
    return;
  }

  fs.mkdirSync(path.dirname(destination), { recursive: true });
  if (!(await installFromRelease(destination, release, target))) {
    console.warn(`Release asset unavailable for ${target}; falling back to Cargo.`);
    installFromCargo(destination, release, target);
  }
}

module.exports = {
  binaryPath,
  detectTarget
};

if (require.main === module) {
  main().catch((error) => {
    console.error(error.message);
    process.exit(1);
  });
}
