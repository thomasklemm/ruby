require 'test/unit'

class TestMethodToken < Test::Unit::TestCase
  def test_revocation_without_application_callbacks
    klass = Class.new { def target = :old }
    klass.define_singleton_method(:method_added) { |_| }
    token = RubyVM.method_token(klass, :target)
    sibling = RubyVM.method_token(klass, :target)
    klass.define_method(:unrelated) { :other }
    assert_predicate token, :valid?
    klass.define_method(:target) { :new }
    assert_not_predicate token, :valid?
    assert_not_predicate sibling, :valid?
    replacement = RubyVM.method_token(klass, :target)
    assert_predicate replacement, :valid?
    GC.start
    assert_not_predicate token, :valid?
  end

  def test_lookup_and_visibility_changes
    operations = [
      ->(k) { k.send(:private, :target) },
      ->(k) { k.alias_method(:target, :other) },
      ->(k) { k.remove_method(:target) },
      ->(k) { k.undef_method(:target) },
      ->(k) { k.prepend(Module.new { def target = :prepended }) }
    ]
    operations.each do |operation|
      klass = Class.new { def target = :old; def other = :other }
      token = RubyVM.method_token(klass, :target)
      operation.call(klass)
      assert_not_predicate token, :valid?
    end
    base = Class.new { def target = :base }
    child = Class.new(base)
    token = RubyVM.method_token(child, :target)
    child.include(Module.new { def target = :included })
    assert_not_predicate token, :valid?

    ancestor = Module.new { def target = :ancestor }
    child = Class.new { include ancestor }
    token = RubyVM.method_token(child, :target)
    ancestor.define_method(:target) { :changed }
    assert_not_predicate token, :valid?
  end

  def test_creation_and_gc_do_not_require_a_ruby_callsite
    assert_separately([], <<~'RUBY')
      $VERBOSE = false
      klass = Class.new
      4.times { |i| klass.define_method("target#{i}") { i } }
      keep = []
      GC.disable
      # Distinct entries and collected heads with live siblings exercise
      # collection after registry growth. No target is called before lookup.
      3.times do |i|
        keep << RubyVM.method_token(klass, "target#{i}")
        RubyVM.method_token(klass, "target#{i}")
      end
      keep << RubyVM.method_token(klass, :target3)
      GC.enable
      GC.start(full_mark: true, immediate_sweep: true)
      assert(keep.all?(&:valid?))
      GC.verify_compaction_references(double_heap: true, toward: :empty)
      assert(keep.all?(&:valid?))
      4.times { |i| klass.define_method("target#{i}") { -i } }
      assert(keep.none?(&:valid?))
    RUBY
  end

  def test_registration_under_gc_stress
    assert_separately([], <<~'RUBY', timeout: 60)
      $VERBOSE = false
      klass = Class.new
      names = 16.times.map { |i| "target#{i}" }
      names.each { |name| klass.define_method(name) { 19 } }
      keep = []
      begin
        GC.stress = true
        names.each do |name|
          keep << RubyVM.method_token(klass, name)
          2.times { RubyVM.method_token(klass, name) }
        end
      ensure
        GC.stress = false
      end
      GC.start(immediate_sweep: false)
      GC.verify_compaction_references(double_heap: true, toward: :empty)
      assert(keep.all?(&:valid?))
      names.each { |name| klass.define_method(name) { 23 } }
      assert(keep.none?(&:valid?))
    RUBY
  end

  def test_multi_ractor_mode_permanently_disables_tokens
    assert_separately([], <<~'RUBY')
      token = RubyVM.method_token(Hash, :each)
      assert_predicate token, :valid?
      ractor = Ractor.new { RubyVM.method_token(Hash, :each) }
      assert_nil ractor.value
      assert_nil RubyVM.method_token(Hash, :each)
      assert_not_predicate token, :valid?
      GC.start
      assert_not_predicate token, :valid?
    RUBY
  end

  def test_fork_cannot_reenable_tokens_after_multi_ractor_mode
    omit "fork is not supported" unless Process.respond_to?(:fork)
    [false, true].each do |mutate|
      assert_separately([], <<~RUBY)
        $VERBOSE = false
        klass = Class.new { def target = :original }
        token = RubyVM.method_token(klass, :target)
        assert_predicate token, :valid?
        Ractor.new { nil }.value
        klass.class_eval("def target = :changed") if #{mutate}
        # No token API call intervenes between entering multi-Ractor mode
        # and fork: disabling must happen at the Ractor transition itself.
        pid = fork do
          exit!(token.valid? == false && RubyVM.method_token(klass, :target).nil? ? 0 : 1)
        end
        assert_predicate Process.wait2(pid).last, :success?
      RUBY
    end
  end

  def test_existing_singleton_and_receiver_class_boundary
    klass = Class.new { def target = :old }
    object = klass.new
    ordinary = RubyVM.method_token(klass, :target)
    object.define_singleton_method(:target) { :singleton }
    # Lookup on klass did not change. A consumer needs a receiver-class guard.
    assert_predicate ordinary, :valid?
    singleton = RubyVM.method_token(object.singleton_class, :target)
    object.define_singleton_method(:target) { :changed }
    assert_not_predicate singleton, :valid?
  end

  def test_missing_methods_are_refused
    assert_nil RubyVM.method_token(Class.new, :never_defined)
    assert_raise(TypeError) { RubyVM.method_token(Module.new, :target) }
    assert_separately([], <<~'RUBY')
      klass = Class.new { def target = :plain }
      Module.new { refine(klass) { def target = :refined } }
      assert_nil RubyVM.method_token(klass, :target)
    RUBY
  end
end
