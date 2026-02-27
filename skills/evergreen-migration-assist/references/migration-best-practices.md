# Migration Best Practices

## Core Principle

Prefer explicit, deterministic mappings that preserve user data.

## Call-The-Shot Protocol

When multiple valid migration mappings exist, present options and get user confirmation before finalizing.

Example:
- Option A: `description = todo.title` (preserve semantic intent)
- Option B: `description = ""` (neutral default)

Do not silently pick among multiple plausible options without user confirmation.

## Field Changes

### Added fields
- Prefer deriving from existing values over hard-coded defaults.
- If a default is required, keep it deterministic and document why.

### Removed fields
- Decide intentionally whether to drop, aggregate, or transform the old data.
- If dropping, leave a short code comment at the mapping site explaining the decision.

### Renamed fields
- Treat as a direct mapping, not a reset.

### Type changes
- Handle conversion explicitly and keep failure cases visible.
- Avoid hidden fallbacks that silently lose information.

## Custom Types

- Use exhaustive pattern matches for old constructors.
- For removed constructors, choose an explicit migration path for each case.
- Avoid wildcard branches for migration logic unless there is a strict proof that all cases are equivalent.

## Model / Msg Migration Semantics

- Avoid `ModelReset` unless destructive reset is explicitly required.
- Avoid `ModelUnchanged` or `MsgUnchanged` for changed types.
- Use `MsgOldValueIgnored` only when intentionally discarding old in-flight messages.

## Review Checklist Before Finalizing

1. No `Unimplemented` or `Debug.todo` remains.
2. Mappings are explicit and readable.
3. Risky semantics (`ModelReset`, `MsgOldValueIgnored`) are intentional and documented.
4. Migration compiles.
5. Full migration tests pass.

## Example Harness Checks

Use an executable migration example harness to verify assumptions against a concrete old model.

Suggested assertion themes:
- Cardinality preserved where expected (list lengths, map sizes).
- Identity preserved (IDs, stable keys).
- New fields initialized intentionally (derived/default values).
- Old data not silently dropped.

Prefer assertions that fail loudly with a clear message instead of only printing output.
