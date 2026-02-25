import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "node:url";

// Resolve relative to this file's location, not process.cwd().
// esbuild compiles this to .elm-pages/compiled-ports/custom-backend-task.mjs,
// so going up 2 levels always reaches the project root.
const __filename = fileURLToPath(import.meta.url);
const PROJECT_ROOT = path.resolve(path.dirname(__filename), "..", "..");
const DB_FILE = path.join(PROJECT_ROOT, "db.bin");

export async function loadDbState(): Promise<string | null> {
  if (!fs.existsSync(DB_FILE)) return null;
  return fs.readFileSync(DB_FILE).toString("base64");
}

export async function saveDbState(b64: string): Promise<null> {
  fs.writeFileSync(DB_FILE, Buffer.from(b64, "base64"));
  return null;
}
