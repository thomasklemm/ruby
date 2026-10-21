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
  end

  def test_creation_and_gc_do_not_require_a_ruby_callsite
    klass = Class.new { def target = 19 }
    # Never invoke target: token acquisition must itself register a dependency.
    keep = Array.new(3) { RubyVM.method_token(klass, :target) }
    10.times do
      100.times { RubyVM.method_token(klass, :target) }
      GC.start
    end
    GC.verify_compaction_references(double_heap: true, toward: :empty)
    assert(keep.all?(&:valid?))
    klass.define_method(:target) { 23 }
    assert(keep.none?(&:valid?))
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
  end
end
