import * as fs from "fs";
import * as path from "path";
import * as crypto from "crypto";
import { fileURLToPath } from "node:url";

// Resolve relative to this file's location, not process.cwd().
// esbuild compiles this to .elm-pages/compiled-ports/custom-backend-task.mjs,
// so going up 2 levels always reaches the project root.
const __filename = fileURLToPath(import.meta.url);
const PROJECT_ROOT = path.resolve(path.dirname(__filename), "..", "..");
const DB_FILE = path.join(PROJECT_ROOT, "db.bin");
const LOCK_FILE = path.join(PROJECT_ROOT, "db.lock");
let lockToken: string | null = null;

export async function atomicSaveDbState(json: string): Promise<null> {
  const tmpFile = DB_FILE + ".tmp." + process.pid;
  try {
    fs.writeFileSync(tmpFile, json, "utf-8");
    fs.renameSync(tmpFile, DB_FILE);
  } catch (e) {
    try {
      fs.unlinkSync(tmpFile);
    } catch {}
    throw e;
  }
  return null;
}

export async function acquireDbLock(): Promise<string> {
  const token = crypto.randomUUID();
  const content = JSON.stringify({
    pid: process.pid,
    createdAt: new Date().toISOString(),
    token,
  });

  const tryAcquire = (): string | null => {
    try {
      fs.writeFileSync(LOCK_FILE, content, { flag: "wx" });
      lockToken = token;
      return token;
    } catch (e: any) {
      if (e.code !== "EEXIST") throw e;
      return null;
    }
  };

  let result = tryAcquire();
  if (result) return result;

  // Lock exists — check if stale
  let existing: any;
  try {
    existing = JSON.parse(fs.readFileSync(LOCK_FILE, "utf-8"));
  } catch {
    // Can't read/parse lock file — remove and retry once
    try {
      fs.unlinkSync(LOCK_FILE);
    } catch {}
    result = tryAcquire();
    if (result) return result;
    throw new Error("db.bin is locked. If stale, delete db.lock");
  }

  let isStale = false;

  // Check if PID is still alive
  if (existing.pid) {
    try {
      process.kill(existing.pid, 0);
    } catch {
      isStale = true;
    }
  }

  // Check if lock is older than 5 minutes
  if (!isStale && existing.createdAt) {
    const age = Date.now() - new Date(existing.createdAt).getTime();
    if (age > 5 * 60 * 1000) {
      isStale = true;
    }
  }

  if (isStale) {
    try {
      fs.unlinkSync(LOCK_FILE);
    } catch {}
    result = tryAcquire();
    if (result) return result;
  }

  throw new Error(
    `db.bin is locked by PID ${existing.pid} since ${existing.createdAt}. If stale, delete db.lock`
  );
}

export async function releaseDbLock(token: string): Promise<null> {
  try {
    const raw = fs.readFileSync(LOCK_FILE, "utf-8");
    const existing = JSON.parse(raw);
    if (existing.token === token) {
      fs.unlinkSync(LOCK_FILE);
      lockToken = null;
    }
  } catch {
    // Lock file already gone or unreadable — that's fine
  }
  return null;
}

// Auto-cleanup lock on process exit
process.on("exit", () => {
  if (lockToken) {
    try {
      const raw = fs.readFileSync(LOCK_FILE, "utf-8");
      const existing = JSON.parse(raw);
      if (existing.token === lockToken) {
        fs.unlinkSync(LOCK_FILE);
      }
    } catch {}
  }
});
