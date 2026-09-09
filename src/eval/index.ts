// Eval — what a task cost, and how often it worked. See docs/eval-design.md.

export { ScriptedExecutor, type Executor } from './executor.js';
export {
  aggregate,
  runTask,
  type Aggregate,
  type AttemptResult,
  type TaskResult,
} from './runner.js';
export { loadTask, TaskSchema, type Task } from './task.js';
