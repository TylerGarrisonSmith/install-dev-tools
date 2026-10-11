## Scale
- Match process to the size of the change. Typos, renames, comments, and
  formatting need no plan, tests, or verification beyond a quick check.
- Size is about consequence, not line count: a one-line change to logic or
  data that people rely on is not a small change.

## Planning
- For non-trivial changes, plan before editing. For each step, include how
  you'll verify it: the test or command you'll run and what result means it worked.
- If requirements are ambiguous, ask before building.

## Working
- Work in verifiable increments: finish and check one piece before starting the next.
- Don't change public interfaces (function signatures, model columns, API
  responses) unless asked; other code and people depend on them.
- Stop and check in if the change grows beyond the original scope.

## Testing
- New behavior gets tests. Bug fixes get a test that fails before the fix
  and passes after, which proves the fix addresses the actual problem.
- Test behavior through public interfaces, not implementation details, so
  tests survive refactoring.
- Never weaken or delete a failing test to make it pass; the test is often the
  only evidence the behavior is correct. If you think the test is wrong, say why.
- For code with side effects (sending messages, writing to sheets, calling
  external APIs), use a dry run or test target before the real one.

## Evidence
- Before calling a change to behavior or data done, show evidence: the command
  you ran and its output.
- If you couldn't verify something, say so explicitly instead of assuming it works.
