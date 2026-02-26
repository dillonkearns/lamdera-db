import * as fs from "fs";
import * as path from "path";
import * as crypto from "crypto";
import * as os from "os";
import { execSync } from "child_process";
import { fileURLToPath } from "node:url";

// Resolve relative to this file's location, not process.cwd().
// esbuild compiles this to .elm-pages/compiled-ports/custom-backend-task.mjs,
// so going up 2 levels always reaches the project root.
const __filename = fileURLToPath(import.meta.url);
const PROJECT_ROOT = path.resolve(path.dirname(__filename), "..", "..");
const DB_FILE = path.join(PROJECT_ROOT, "db.bin");

export async function loadDbState(): Promise<string | null> {
  if (!fs.existsSync(DB_FILE)) return null;
  return fs.readFileSync(DB_FILE, "utf-8");
}

export async function saveDbState(json: string): Promise<null> {
  fs.writeFileSync(DB_FILE, json, "utf-8");
  return null;
}

export async function runSnapshot(): Promise<{
  previousVersion: number;
  newVersion: number;
  files: string[];
}> {
  const files: string[] = [];

  // 1. Read current version from SchemaVersion.elm
  const schemaVersionPath = path.join(PROJECT_ROOT, "lib", "SchemaVersion.elm");
  const schemaContent = fs.readFileSync(schemaVersionPath, "utf-8");
  const match = schemaContent.match(/current\s*=\s*(\d+)/);
  if (!match) throw new Error("Could not parse version from lib/SchemaVersion.elm");
  const N = parseInt(match[1], 10);
  const K = N + 1;

  // 2. Create snapshot: src/Evergreen/V{N}/Types.elm
  const snapshotDir = path.join(PROJECT_ROOT, "src", "Evergreen", `V${N}`);
  fs.mkdirSync(snapshotDir, { recursive: true });
  const typesContent = fs.readFileSync(
    path.join(PROJECT_ROOT, "src", "Types.elm"),
    "utf-8"
  );
  const snapshotContent = typesContent.replace(
    /^module Types/,
    `module Evergreen.V${N}.Types`
  );
  const snapshotPath = path.join(snapshotDir, "Types.elm");
  fs.writeFileSync(snapshotPath, snapshotContent, "utf-8");
  files.push(`src/Evergreen/V${N}/Types.elm`);

  // 3. Rewrite existing migration's import Types → import Evergreen.V{N}.Types as Types
  const migrateDir = path.join(
    PROJECT_ROOT,
    "src",
    "Evergreen",
    "Migrate"
  );
  const migratePath = path.join(migrateDir, `V${N}.elm`);
  if (fs.existsSync(migratePath)) {
    let migrateContent = fs.readFileSync(migratePath, "utf-8");
    migrateContent = migrateContent.replace(
      /^import Types\b/gm,
      `import Evergreen.V${N}.Types as Types`
    );
    fs.writeFileSync(migratePath, migrateContent, "utf-8");
    files.push(`src/Evergreen/Migrate/V${N}.elm`);
  }

  // 4. Create migration stub V{K}
  fs.mkdirSync(migrateDir, { recursive: true });
  const stubPath = path.join(migrateDir, `V${K}.elm`);
  const stubContent = [
    `module Evergreen.Migrate.V${K} exposing (backendModel)`,
    "",
    `import Evergreen.V${N}.Types`,
    "import Types",
    "",
    "",
    `backendModel : Evergreen.V${N}.Types.BackendModel -> Types.BackendModel`,
    "backendModel old =",
    "    -- TODO: implement migration",
    `    Debug.todo "Implement V${N} -> V${K} migration"`,
    "",
  ].join("\n");
  fs.writeFileSync(stubPath, stubContent, "utf-8");
  files.push(`src/Evergreen/Migrate/V${K}.elm`);

  // 5. Generate script/Migrate.elm
  const migrateElm = generateMigrateElm(N);
  const migrateElmPath = path.join(PROJECT_ROOT, "script", "Migrate.elm");
  fs.writeFileSync(migrateElmPath, migrateElm, "utf-8");
  files.push("script/Migrate.elm");

  // 6. Bump SchemaVersion.elm to K
  const newSchemaContent = schemaContent.replace(
    /current\s*=\s*\d+/,
    `current = ${K}`
  );
  fs.writeFileSync(schemaVersionPath, newSchemaContent, "utf-8");
  files.push("lib/SchemaVersion.elm");

  return { previousVersion: N, newVersion: K, files };
}

export async function compareBackendModelShape(args: {
  storedTypes: string;
  currentTypes: string;
}): Promise<{ result: "Same" | "Different" | "Error"; message?: string }> {
  const tmpTypes = path.join(PROJECT_ROOT, "script", "LamderaDbDeepCheckTmpTypes.elm");
  const tmpWitness = path.join(PROJECT_ROOT, "script", "LamderaDbDeepCheckTmpWitness.elm");
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "lamdera-deep-check-"));

  const witnessContent = [
    "module LamderaDbDeepCheckTmpWitness exposing (main)",
    "",
    "import LamderaDbDeepCheckTmpTypes exposing (..)",
    "import Platform",
    "",
    "main =",
    '    Platform.worker',
    '        { init = \\() -> ( w3_encode_BackendModel, Cmd.none )',
    '        , update = \\_ m -> ( m, Cmd.none )',
    '        , subscriptions = \\_ -> Sub.none',
    '        }',
    "",
  ].join("\n");

  try {
    // --- Compile stored types ---
    const storedModule = args.storedTypes.replace(
      /^module Types/m,
      "module LamderaDbDeepCheckTmpTypes"
    );
    fs.writeFileSync(tmpTypes, storedModule, "utf-8");
    fs.writeFileSync(tmpWitness, witnessContent, "utf-8");

    const storedJs = path.join(tmpDir, "stored.js");
    try {
      execSync(
        `lamdera make script/LamderaDbDeepCheckTmpWitness.elm --output=${storedJs}`,
        { cwd: PROJECT_ROOT, stdio: "pipe" }
      );
    } catch (e: any) {
      return {
        result: "Error",
        message: "Failed to compile stored types: " + (e.stderr?.toString() || e.message),
      };
    }

    const storedHash = crypto
      .createHash("sha256")
      .update(fs.readFileSync(storedJs))
      .digest("hex");

    // --- Compile current types ---
    const currentModule = args.currentTypes.replace(
      /^module Types/m,
      "module LamderaDbDeepCheckTmpTypes"
    );
    fs.writeFileSync(tmpTypes, currentModule, "utf-8");

    const currentJs = path.join(tmpDir, "current.js");
    try {
      execSync(
        `lamdera make script/LamderaDbDeepCheckTmpWitness.elm --output=${currentJs}`,
        { cwd: PROJECT_ROOT, stdio: "pipe" }
      );
    } catch (e: any) {
      return {
        result: "Error",
        message: "Failed to compile current types: " + (e.stderr?.toString() || e.message),
      };
    }

    const currentHash = crypto
      .createHash("sha256")
      .update(fs.readFileSync(currentJs))
      .digest("hex");

    if (storedHash === currentHash) {
      // Update stored fingerprint so future reads hit the fast path
      try {
        const raw = fs.readFileSync(DB_FILE, "utf-8");
        const envelope = JSON.parse(raw);
        envelope.t = args.currentTypes;
        fs.writeFileSync(DB_FILE, JSON.stringify(envelope), "utf-8");
      } catch {}
      return { result: "Same" };
    }
    return { result: "Different" };
  } catch (e: any) {
    return {
      result: "Error",
      message: "Deep check failed: " + e.message,
    };
  } finally {
    // Clean up temp .elm files
    try { fs.unlinkSync(tmpTypes); } catch {}
    try { fs.unlinkSync(tmpWitness); } catch {}
    // Clean up temp JS output dir
    try { fs.rmSync(tmpDir, { recursive: true }); } catch {}
  }
}

function generateMigrateElm(N: number): string {
  // N = version before bump. New version K = N + 1.
  // Old versions to handle in case branches: 1..N
  // Migration modules: V2..VK
  // Snapshot type modules: V1..VN
  const K = N + 1;

  // --- Imports ---
  const imports: string[] = [
    "import BackendTask exposing (BackendTask)",
  ];
  for (let i = 2; i <= K; i++) {
    imports.push(`import Evergreen.Migrate.V${i} as MigrateV${i}`);
  }
  for (let i = 1; i <= N; i++) {
    imports.push(`import Evergreen.V${i}.Types`);
  }
  imports.push(
    "import FatalError exposing (FatalError)",
    "import LamderaDb.Migration",
    "import Lamdera.Wire3 as Wire",
    "import Pages.Script as Script exposing (Script)",
    "import SchemaVersion",
    "import Types"
  );

  // --- Case branches ---
  const caseBranches: string[] = [];
  for (let i = 1; i <= N; i++) {
    caseBranches.push(
      [
        `                        ${i} ->`,
        `                            case Wire.bytesDecode Evergreen.V${i}.Types.w3_decode_BackendModel bytes of`,
        `                                Just v${i}Model ->`,
        `                                    migrateFromV${i} v${i}Model`,
        "",
        "                                Nothing ->",
        "                                    BackendTask.fail",
        "                                        (FatalError.build",
        `                                            { title = "V${i} decode failed"`,
        `                                            , body = "Could not decode db.bin as V${i} BackendModel."`,
        "                                            }",
        "                                        )",
      ].join("\n")
    );
  }

  // --- Chain functions ---
  const chainFunctions: string[] = [];
  for (let i = 1; i <= N; i++) {
    if (i < N) {
      chainFunctions.push(
        [
          "",
          "",
          `migrateFromV${i} : Evergreen.V${i}.Types.BackendModel -> BackendTask FatalError ()`,
          `migrateFromV${i} model =`,
          `    migrateFromV${i + 1} (MigrateV${i + 1}.backendModel model)`,
        ].join("\n")
      );
    } else {
      chainFunctions.push(
        [
          "",
          "",
          `migrateFromV${i} : Evergreen.V${i}.Types.BackendModel -> BackendTask FatalError ()`,
          `migrateFromV${i} model =`,
          "    let",
          "        currentModel =",
          `            MigrateV${K}.backendModel model`,
          "    in",
          "    saveAndLog currentModel",
        ].join("\n")
      );
    }
  }

  return [
    "module Migrate exposing (run)",
    "",
    imports.join("\n"),
    "",
    "",
    "run : Script",
    "run =",
    "    Script.withoutCliOptions",
    "        (LamderaDb.Migration.readVersioned",
    "            |> BackendTask.andThen",
    "                (\\{ version, bytes } ->",
    "                    case version of",
    caseBranches.join("\n\n"),
    "",
    "                        _ ->",
    '                            if version == SchemaVersion.current then',
    '                                Script.log ("db.bin is already at version " ++ String.fromInt version ++ ". No migration needed.")',
    "",
    "                            else",
    "                                BackendTask.fail",
    "                                    (FatalError.build",
    '                                        { title = "Unknown version"',
    '                                        , body = "db.bin is at version " ++ String.fromInt version ++ " but no migration path is defined."',
    "                                        }",
    "                                    )",
    "                )",
    "        )",
    ...chainFunctions,
    "",
    "",
    "saveAndLog : Types.BackendModel -> BackendTask FatalError ()",
    "saveAndLog currentModel =",
    "    let",
    "        bytes =",
    "            Wire.bytesEncode (Types.w3_encode_BackendModel currentModel)",
    "    in",
    "    LamderaDb.Migration.writeVersioned SchemaVersion.current bytes",
    "        |> BackendTask.andThen",
    "            (\\_ ->",
    "                Script.log",
    '                    ("Migrated db.bin to version "',
    "                        ++ String.fromInt SchemaVersion.current",
    "                    )",
    "            )",
    "",
  ].join("\n");
}