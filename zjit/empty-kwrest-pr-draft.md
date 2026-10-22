# Fork-only PR draft — not submitted upstream

## Title

ZJIT: Support direct sends with empty keyword rest arguments

## Proposed body

Allow `SendDirect` to call a method with `**kwargs` when the caller passes no
keywords and the callee has neither named keyword parameters nor anonymous
positional rest. Pass a fresh empty Hash for named `**kwargs`, or nil for
anonymous `**`, matching `args_setup_kw_rest_parameter`. Keep kwrest out of
the general inliner and leave other cases on VM dispatch.

This uses the existing argument planner and `KeywordHash` HIR; no VM or public
API changes. The kwrest slot is included in the direct-call argument count and
excluded from positional optional/rest/post argument processing.

### Measurements

Base: [ruby/ruby 5f2bc22560](https://github.com/ruby/ruby/commit/5f2bc22560e9063fb8dec736afbf378251cad3ec), x86_64 Linux, both
JITs built with stats support, **stats disabled in wall workers**. Ten rotated
paired rounds, 2,000,000 calls per worker, 100 calls of a 2,000-iteration caller
for warmup; intervals are 95% paired-round bootstrap intervals (5,000 resamples).
The benchmark checks its result and both actual JIT enablement states.

```ruby
def empty_keywords(**kwargs) = kwargs.empty?
def hot_loop(n)
  i = 0
  matches = 0
  while i < n
    matches += 1 if empty_keywords
    i += 1
  end
  matches
end
```

| Mode | Base mean | Patched mean | Paired elapsed change | A/A elapsed change |
|---|---:|---:|---:|---:|
| ZJIT | 107.23 ms | 40.10 ms | −62.49% [−63.90%, −61.55%] | −0.14% [−4.51%, +3.27%] |
| Interpreter | 142.32 ms | 147.72 ms | +3.80% [+1.15%, +6.95%] | +1.54% [−0.52%, +3.85%] |

Both modes allocate 2,000,007 objects on both binaries. Separate untimed HIR
and stats workers confirm the caller compiled and its kwrest fallbacks went
from 2,000,000 to zero, without compilation during the measured window.

The interpreter wall observation is retained, not called a speedup or hidden.
The executable patch is entirely under `zjit/`. Callgrind on the interpreter
finds **exactly equal** instruction counts on both binaries:

| Calls | Base Ir | Patched Ir |
|---:|---:|---:|
| 0 | 2,732 | 2,732 |
| 5,000 | 3,988,012 | 3,988,012 |
| 10,000 | 8,052,482 | 8,052,482 |

At 10,000 calls both allocate 10,006 objects. The zero-window seam is included
above; subtracting it gives 804.975 Ir/call on both binaries at 10,000 calls.
GC is disabled only in this instruction-count micro window. This establishes
no added interpreter instruction work, not equal wall time or a proven cause
for its timing variation.

Supporting Rails 8.1.4 context: blog `GET /articles/1` and a small Fizzy
`GET /buckets` fixture remove **15 and 6 kwrest fallbacks/request**. Both entropy
seeds have identical response body/header digests across base/base/patch and
allocations are unchanged within A/A. The three-round whole-request wall
screen does **not** resolve a gain: blog −0.29% (A/A +5.05%); Fizzy +1.12%
(A/A −0.16%). This is a direct-send coverage improvement, not a Rails
throughput claim.

### Tests

`make zjit-test ZJIT_TEST_FEATURES=disasm ZJIT_TESTS='-j 4'`:
**1,886 passed, 15 skipped** on x86_64 Linux.

Added executable cases cover fresh Hash identity/mutation, anonymous keyword
forwarding, asymmetric required/optional/rest/post arguments, and a callee
compile-failure stub exit with an omitted optional argument. The existing HIR
test now requires a guarded `SendDirect` with `NewHash`, instead of a generic
send with the kwrest fallback counter.

## Owner review notes (not part of the short PR body)

- Do not submit without the owner's approval. No GitHub PR, issue, review,
  comment, or Ruby bug-tracker post was made for this work.
- Measurements, complete paired rows, failed iterations, and the runnable
  benchmark are in the Lowrail `thomasklemm/jit-hooks` branch:
  `docs/jit-internals.md`, `docs/jit-internals.json`,
  `bench/experiments/jit_hooks.rb` (`micro` subcommand).
- Do not broaden by just deleting the rejection: named keyword parameters
  introduce a hidden keyword-bits local before kwrest. The existing stub
  spill/exit code must handle that gap first. An exploratory wider version
  failed during Fizzy route initialization and was discarded.
- Anonymous positional rest is also deliberately refused: VM empty-rest
  sharing differs from `RestArray` packing; a wider version added 4/13
  objects/request on these fixtures. No allocation regression is hidden.
- Caller literal keywords and runtime `**hash` are separate follow-ups; the
  latter is rejected before this planner. No AArch64, hosted CI, full
  ruby-spec, or full Rails test-suite claim is made here.
