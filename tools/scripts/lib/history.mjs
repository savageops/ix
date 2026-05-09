import { existsSync, readFileSync } from "node:fs";

export function loadHistory(jsonlPath) {
  if (!existsSync(jsonlPath)) {
    return [];
  }

  return readFileSync(jsonlPath, "utf8")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}

export function latest(history) {
  if (history.length === 0) {
    return null;
  }
  return history[history.length - 1];
}
