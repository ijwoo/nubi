/**
 * Words that mark an action as one you cannot take back.
 *
 * A heuristic, and one deliberately biased toward caution: a false positive
 * costs a confirmation the person taps through, a false negative spends their
 * money or deletes their data. Kept narrow enough to avoid flagging every
 * screen — "확인" alone is too common to mean anything.
 *
 * Shared because two very different places need the same answer. Macro
 * extraction uses it to decide what needs an approval gate (ADR 0007). Repair
 * uses it to refuse a replacement that is more dangerous than what it replaces
 * — a repair is written into the macro permanently, so a wrong one is not a
 * bad run but a bad macro.
 */
const IRREVERSIBLE = [
  '결제',
  '구매',
  '주문',
  '결재',
  '송금',
  '이체',
  '삭제',
  '지우기',
  '제거',
  '탈퇴',
  '전송',
  '보내기',
  '발송',
  '게시',
  'pay',
  'buy',
  'purchase',
  'checkout',
  'subscribe',
  'delete',
  'remove',
  'erase',
  'send',
  'post',
  'publish',
];

/** Whether any of `texts` names something irreversible. */
export function isIrreversible(...texts: (string | undefined)[]): boolean {
  const joined = texts
    .filter((t): t is string => t !== undefined)
    .join(' ')
    .toLowerCase();
  return IRREVERSIBLE.some((word) => joined.includes(word));
}
