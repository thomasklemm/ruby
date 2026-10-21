# frozen_string_literal: false
require 'test/unit'
require '-test-/method'

class TestMethodToken < Test::Unit::TestCase
  def token(klass, name = :target)
    Bug::Method.token(klass, name)
  end

  def valid?(token)
    Bug::Method.token_valid?(token)
  end

  def test_suppressed_hooks_and_unrelated_changes
    klass = Class.new do
      def self.method_added(*) = nil
      def target = :before
    end
    first = token(klass)
    assert valid?(first)
    klass.class_eval { def unrelated = :other }
    assert valid?(first)
    klass.class_eval { def target = :after }
    assert_equal :after, klass.new.target
    assert_equal false, valid?(first)
    assert valid?(token(klass))
    klass.class_eval { def target = :before }
    assert_equal false, valid?(first)
  end

  def test_lookup_changes_without_a_callsite
    [:redefine, :remove, :undef, :alias, :private, :include, :prepend].each do |change|
      parent = Class.new { def target = :parent }
      klass = Class.new(parent)
      klass.class_eval { def target = :own } unless change == :include
      first = token(klass)
      case change
      when :redefine then parent.class_eval { def target = :changed }; klass.remove_method(:target)
      when :remove then klass.remove_method(:target)
      when :undef then klass.undef_method(:target)
      when :alias
        klass.class_eval { def other = :other; alias_method :target, :other }
      when :private then klass.send(:private, :target)
      when :include then klass.include(Module.new { def target = :included })
      when :prepend then klass.prepend(Module.new { def target = :prepended })
      end
      assert_equal false, valid?(first), change.to_s
    end
  end

  def test_inherited_and_included_methods
    [Class.new { def target = :old }, Module.new { def target = :old }].each do |owner|
      klass = owner.is_a?(Class) ? Class.new(owner) : Class.new { include owner }
      subclass = Class.new(klass) # exercise tree, not only leaf invalidation
      first, second = token(klass), token(subclass)
      owner.module_eval { def target = :new }
      assert_equal false, valid?(first)
      assert_equal false, valid?(second)
      assert valid?(token(klass))
    end
  end

  def test_singleton_method_and_receiver_boundary
    klass = Class.new { def target = :ordinary }
    object = klass.new
    ordinary = token(klass)
    object.define_singleton_method(:target) { :singleton }
    assert valid?(ordinary) # consumers must check the actual receiver class
    singleton = token(object.singleton_class)
    object.define_singleton_method(:singleton_method_added) { |_| }
    object.define_singleton_method(:target) { :changed }
    assert_equal false, valid?(singleton)
  end

  def test_missing_refined_and_invalid_arguments
    assert_nil token(Class.new)
    assert_raise(TypeError) { token(Module.new) }
    [nil, true, 42, Object.new].each do |obj|
      assert_raise(TypeError) { valid?(obj) }
    end
    klass = Class.new { def target = :original }
    Module.new { refine(klass) { def target = :refined } }
    assert_nil token(klass)
  end

  def test_gc_lifetime
    klass = Class.new { def target = :kept }
    first = token(klass)
    3.times { GC.start }
    GC.verify_compaction_references(double_heap: true, toward: :empty)
    assert valid?(first)
    assert_equal :kept, klass.new.target
    assert_separately([], <<~'RUBY')
      require '-test-/method'
      $VERBOSE = nil
      klass = Class.new { def target = :kept }
      GC.stress = true
      tokens = Array.new(20) { Bug::Method.token(klass, :target) }
      tokens.each { |t| assert Bug::Method.token_valid?(t) }
      klass.class_eval { def target = :new }
      tokens.each { |t| assert_equal false, Bug::Method.token_valid?(t) }
    RUBY
  end

  def test_collected_class_revokes_token
    require 'weakref'
    pairs = Array.new(100) do
      klass = Class.new { def target = :temporary }
      [WeakRef.new(klass), token(klass)]
    end
    [false, true, false, true].each do |full_mark|
      GC.start(full_mark: full_mark, immediate_sweep: true)
      pairs.each do |ref, t|
        assert_equal false, valid?(t) unless ref.weakref_alive?
      end
    end
    assert pairs.any? { |ref, _| !ref.weakref_alive? }, 'must collect a class'
  end

  def test_ractor_and_fork
    assert_separately([], <<~'RUBY')
      require '-test-/method'
      $VERBOSE = nil
      klass = Class.new { def target = :old; def stable = :kept }
      first = Bug::Method.token(klass, :target)
      unchanged = Bug::Method.token(klass, :stable)
      r = Ractor.new { :done }
      r.value
      assert_equal false, Bug::Method.token_valid?(first)
      assert_nil Bug::Method.token(klass, :target)
      klass.class_eval { def target = :new }
      if Process.respond_to?(:fork)
        pid = fork do
          assert_equal false, Bug::Method.token_valid?(first)
          assert Bug::Method.token_valid?(unchanged)
          assert Bug::Method.token_valid?(Bug::Method.token(klass, :target))
        end
        Process.wait(pid)
        assert_predicate $?, :success?
      end
    RUBY
  end

  def test_box_is_not_supported
    assert_separately([{'RUBY_BOX' => '1'}], <<~'RUBY')
      require '-test-/method'
      assert_nil Bug::Method.token(String, :length)
    RUBY
  end
end
