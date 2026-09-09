import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

/**
 * Load credentials from a gitignored `.env`, if there is one.
 *
 * Node 22 reads the file natively, so this needs no dependency. Called from
 * the scripts that talk to the API rather than from library code: a test or a
 * fake-backed run must not quietly pick up a key and start spending money.
 *
 * An existing environment variable always wins — a key exported for one
 * command should not be overridden by a file left behind from last week.
 */
export function loadEnv(): void {
  const file = fileURLToPath(new URL('../../.env', import.meta.url));
  if (!existsSync(file)) return;
  const before = process.env.ANTHROPIC_API_KEY;
  process.loadEnvFile(file);
  if (before) process.env.ANTHROPIC_API_KEY = before;
}

/** Whether a model call is possible at all, so scripts can say so up front. */
export function hasApiKey(): boolean {
  return Boolean(process.env.ANTHROPIC_API_KEY);
}
