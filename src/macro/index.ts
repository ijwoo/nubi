// Macro — routes that were learned once. See docs/macro-format.md.

export { extractMacro, type ExtractOptions } from './extract.js';
export { ReplayExecutor, type ReplayOptions } from './replay.js';
export {
  ScriptedRepairer,
  isWorthKeeping,
  repairedStep,
  type RepairContext,
  type Repairer,
  type RepairSuggestion,
} from './repair.js';
export { MacroStore } from './store.js';
