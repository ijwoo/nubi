// Hands — everything Nubi knows about talking to a phone.
// See docs/architecture.md.

export { compact, estimateTokens, hashElements } from './compact.js';
export { FakeHands, ScenarioSchema, type FakeCall, type Scenario } from './fake.js';
export { resolve, resolveWithFallback, type Resolution, type Rung } from './selector.js';
export type {
  ActResult,
  AssertResult,
  FindResult,
  Hands,
  Health,
  MissReason,
  Point,
} from './types.js';
export {
  contentOf,
  identifierOf,
  labelOf,
  shortType,
  wdaBool,
  type WdaNode,
  type WdaSourceResponse,
} from './wda-types.js';
