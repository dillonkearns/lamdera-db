// custom-backend-task.ts
import * as fs from "fs";
import * as path from "path";
var DB_FILE = path.resolve(process.cwd(), "..", "db.bin");
async function loadDbState() {
  if (!fs.existsSync(DB_FILE)) return null;
  return Array.from(fs.readFileSync(DB_FILE));
}
async function saveDbState(bytes) {
  fs.writeFileSync(DB_FILE, Buffer.from(bytes));
  return null;
}
export {
  loadDbState,
  saveDbState
};
