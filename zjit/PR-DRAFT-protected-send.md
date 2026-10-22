# ZJIT: Guard protected sends with the runtime caller self

Fork-only, draft-eligible under the owner's workload-dependent Ir rule; not
posted upstream. This branch is stacked on the literal-kwrest branch
(46631773), but this protected-send change does NOT depend on ruby/ruby#19478
or literal kwrest. Its four source/test file diff applies cleanly to ruby
master 8ff4ae135d438314090f0dc23916601ef9c444d5 (git apply --cached --check
against a temporary master index); master-alone execution was not measured.
Remove all PR-DRAFT files from any upstream diff. Owner approval is required
before posting.

For non-FCALL protected sends in a non-inlined frame, test the actual runtime
caller self against the callable method entry's defining class/module using
the existing IsA instruction. Exit to the VM when the test fails. Normalize
an internal ICLASS to its included module. Keep the normal receiver-class and
method-entry guards/invalidation. Do not infer permission from the ISEQ owner.
Inlined frames and refined method entries remain on VM dispatch; private and
FCALL behavior is unchanged. The IsA debug validator accepts Module operands,
matching its existing rb_obj_is_kind_of code generation.

The focused Rails-like inherited-options micro has ten rotated paired rounds,
base/A/A/patch in interpreter, YJIT and ZJIT. All rounds are retained. ZJIT
elapsed changes by -36.45% (95% interval -38.75% to -34.95%), with A/A -0.63%
(-4.47% to +3.15%). Untimed permission fallbacks fall from 4,000 to zero for
2,000 iterations; results and allocations are unchanged. No whole-app speed
claim, JIT-flat claim, or Rails support claim.

YJIT elapsed is +3.61% (+1.26% to +6.80%), with a real A/A arm at +1.90%
(-1.77% to +7.67%). Interpreter elapsed is unresolved. Wall times are
informational; no rerun was selected for green.

The timed version has exactly identical fixed-seed base/A/A/patch Callgrind
Ir at N=0/5,000/10,000: interpreter 3,056 / 16,198,056 / 32,393,056; YJIT
889,446 / 10,494,681 / 19,859,681. The later debug-validator-only correction
adds 32 bytes to validate_types and leaves all other normalized text-symbol
sizes unchanged. Its interpreter Ir is still identical. Its YJIT raw totals
are 14 higher at every N, exclusively in unchanged hashbrown insertion of
pointer-keyed Block entries during compilation. Subtracting the N=0 seam
gives identical work Ir. Strict raw equality of the final binary is not met;
the owner admitted this attributed constant layout effect because equality
applies to workload-dependent Ir. The timing cohort was not rerun after this
validation-only edit.

The fixed-getrandom shim is only for disposable instruction-count controls,
not apps or timing. No changed ZJIT compiler code runs with --disable-zjit
--yjit; unchanged ZJIT boot/annotation hooks still exist even when disabled.

Blog GET /articles/1 and authenticated Fizzy GET /buckets preserve exact body
and full-header digests for two seeds, including complete 300-response
sequences per seed. Permission fallbacks/request change 87 -> 1 and 353 -> 9;
total send fallbacks fall by exactly 86 and 344. Side exits do not increase.

Validation: make zjit-check ZJIT_TEST_FEATURES=disasm ZJIT_TESTS='-j 4'
passes 1,894 Rust tests (15 skipped), plus 27 CLI tests / 7,394 assertions.
Keyword/call/method tests pass in interpreter, YJIT, ZJIT, and no-inline ZJIT:
280 tests / 4,541 assertions per mode. Tests cover shared-ISEQ runtime-self
changes, subclass/sibling callers, module ownership, singleton-class callers,
refinements and protected/public/private transitions after compilation.
Removing the complete permission guard changes denied sibling/singleton
results to successful protected calls; restoring it passes.

Full evidence and reproduction: thomasklemm/lowrail branch
thomasklemm/zjit-fallbacks-2, docs/zjit-fallbacks-2.md and .json.
AArch64, hosted CI, full ruby-spec, and full Rails suites were not run.
