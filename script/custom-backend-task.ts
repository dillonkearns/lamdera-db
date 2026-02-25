import * as fs from "fs";
import * as path from "path";

const DB_FILE = path.resolve(process.cwd(), "..", "db.bin");

export async function loadDbState(): Promise<number[] | null> {
  if (!fs.existsSync(DB_FILE)) return null;
  return Array.from(fs.readFileSync(DB_FILE));
}

export async function saveDbState(bytes: number[]): Promise<null> {
  fs.writeFileSync(DB_FILE, Buffer.from(bytes));
  return null;
}
