#!/usr/bin/env node
import { spawn } from "node:child_process";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { mkdir, writeFile, rm } from "node:fs/promises";
import { createRequire } from "node:module";

const __dirname = dirname(fileURLToPath(import.meta.url));
const frontendDir = join(__dirname, "..");
const repoRoot = join(frontendDir, "..");
const stateDir = join(repoRoot, ".run");

await mkdir(stateDir, { recursive: true });

const pidFile = join(stateDir, "frontend-dev.pid");

const command = process.platform === "win32" ? "npm.cmd" : "npm";
const args = ["run", "dev", "--", "--host", "0.0.0.0", ...process.argv.slice(2)];

const child = spawn(command, args, {
  cwd: frontendDir,
  stdio: "inherit",
  shell: process.platform === "win32",
});

await writeFile(pidFile, String(child.pid), { encoding: "utf8" });

const cleanup = async () => {
  try {
    await rm(pidFile);
  } catch (err) {
    if (err.code !== "ENOENT") {
      console.warn(`[frontend] failed to remove pid file ${pidFile}: ${err.message}`);
    }
  }
};

const forward = (signal) => {
  if (child.killed) {
    return;
  }
  child.kill(signal);
};

["SIGINT", "SIGTERM", "SIGHUP"].forEach((sig) => {
  process.on(sig, () => {
    forward(sig);
  });
});

child.on("exit", async (code, signal) => {
  await cleanup();
  if (signal) {
    process.kill(process.pid, signal);
  } else {
    process.exit(code ?? 0);
  }
});

child.on("error", async (err) => {
  await cleanup();
  console.error("[frontend] failed to start Vite:", err);
  process.exit(1);
});
