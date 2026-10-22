# ZJIT: Support direct sends with literal keyword rest

Fork-only draft. Depends on ruby/ruby#19478; wait for its review and owner
approval before posting. Remove this draft file from any upstream diff.

Allow direct sends to `**kwrest` methods with literal keyword arguments,
including callees with named required/optional keywords. Reuse `NewHash` for
the remaining keywords in caller order, with a fresh Hash on every call.
Preserve named defaults and the existing keyword-bits convention. The lazy
callee stub spills kwrest beyond the hidden bits local and excludes it from
optional-positional reshuffling on interpreter exit.

Dynamic keyword/positional splats, literal-keyword calls passing blocks,
anonymous positional `*`, and no-keyword calls to mixed named/kwrest callees
remain on VM dispatch. No new general-inliner support or VM changes.

On x86-64 Linux, ten rotated paired rounds of two million calls to
`def literal_keywords(a: 13, **kw) = a + kw[:left] - kw[:right]`:

| | #19478 head | this patch |
|---|---:|---:|
| ZJIT elapsed (mean) | 266.28 ms | 134.88 ms |
| Kwrest fallbacks (separate untimed runs) | 2,000,000 | 0 |
| Allocations, interpreter and ZJIT | 2,000,007 | 2,000,007 |

Paired elapsed change is −48.85% [−52.28%, −46.00%]. ZJIT A/A drift is
−5.18% [−10.49%, −0.84%]; retain that caveat, not a rerun selected for green.
Interpreter elapsed is +3.95% [+0.36%, +7.63%], A/A +0.53% [−2.93%, +4.30%].
All executable changes are under `zjit/`. Fixed-hash-seed interpreter
Callgrind Ir agrees exactly across base/A/A/patch at N=0/5000/10000:
2,990 / 9,678,410 / 19,628,965. The initial unseeded Ir difference was entirely
in unchanged `hash.c::any_hash` sign normalization. The fixed-seed helper is
used only for the disposable interpreter instruction-count control, never
for app or elapsed measurements. Equal Ir does not establish equal wall time.

Blog/Fizzy production Rack screens have matching body/full-header digests for
two entropy seeds and reduce kwrest fallback increments/request by 31/255
(62→31 / 343→88 relative to #19478). These are diagnostic counter windows,
not a whole-app speedup or full Rails verification claim.

Validation: `make zjit-check ZJIT_TEST_FEATURES=disasm ZJIT_TESTS='-j 4'`
(1,891 passed, 15 skipped; 27 CLI tests). Keyword/call/method tests pass under
ZJIT with inlining on and with `--zjit-inline-max-iterations=0` (280 each).
New tests cover Hash freshness/order/defaults, named keyword defaults,
anonymous `**`, and forced stub compilation failure with positional gaps.
Removing only the stub fix reproduces `Hash (expected set)` in the new test.
AArch64, hosted CI, full ruby-spec, and full Rails suites were not run.
