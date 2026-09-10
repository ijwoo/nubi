// Gate — asking a person before something irreversible. See ADR 0007.

export {
  DenyingGate,
  ScriptedGate,
  reasonsToAsk,
  verdictFor,
  type Approval,
  type ApprovalRequest,
  type Gate,
} from './gate.js';
export { TerminalGate, prompt, type TerminalGateOptions } from './terminal.js';
