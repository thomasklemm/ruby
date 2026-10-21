require 'test/unit'

class TestMutationEpoch < Test::Unit::TestCase
  def test_structural_changes_without_callbacks_or_constant_caches
    klass = Class.new { def target = :old }
    klass.define_singleton_method(:method_added) { |_| }
    before = RubyVM.mutation_epoch
    klass.define_method(:target) { :new }
    assert_not_equal before, RubyVM.mutation_epoch
    before = RubyVM.mutation_epoch
    klass.send(:private, :target)
    assert_not_equal before, RubyVM.mutation_epoch

    mod = Module.new
    mod.define_singleton_method(:const_added) { |_| }
    before = RubyVM.mutation_epoch
    mod.const_set(:UncachedTarget, 19)
    assert_not_equal before, RubyVM.mutation_epoch
    before = RubyVM.mutation_epoch
    mod.send(:remove_const, :UncachedTarget)
    assert_not_equal before, RubyVM.mutation_epoch
  end

  def test_method_and_ancestry_changes
    klass = Class.new { def target = :old }
    object = klass.new
    mixin = Module.new { def target = :mixin }
    other = Module.new { def another = :other }
    fresh = Object.new
    operations = [
      -> { klass.alias_method(:aliased, :target) },
      -> { klass.remove_method(:aliased) },
      -> { klass.undef_method(:target) },
      -> { klass.include(mixin) },
      -> { klass.prepend(other) },
      -> { object.extend(other) },
      -> { fresh.singleton_class },
      -> { fresh.define_singleton_method(:target) { :singleton } }
    ]
    operations.each do |operation|
      saved = RubyVM.mutation_epoch
      operation.call
      assert_not_equal saved, RubyVM.mutation_epoch
    end
  end

  def test_autoload_and_constant_visibility
    require 'tmpdir'
    mod = Module.new
    self.class.const_set(:AutoloadHost, mod)
    Dir.mktmpdir('mutation-epoch') do |dir|
      path = File.join(dir, 'autoload_target.rb')
      File.write(path, "TestMutationEpoch::AutoloadHost::Target = 19")
      saved = RubyVM.mutation_epoch
      mod.autoload(:Target, path)
      assert_not_equal saved, RubyVM.mutation_epoch
      saved = RubyVM.mutation_epoch
      assert_equal 19, mod.const_get(:Target)
      assert_not_equal saved, RubyVM.mutation_epoch
      saved = RubyVM.mutation_epoch
      mod.private_constant(:Target)
      assert_not_equal saved, RubyVM.mutation_epoch
      mod.autoload(:Unloaded, File.join(dir, 'never_loaded.rb'))
      saved = RubyVM.mutation_epoch
      mod.send(:remove_const, :Unloaded)
      assert_not_equal saved, RubyVM.mutation_epoch
    end
  ensure
    self.class.send(:remove_const, :AutoloadHost)
  end

  def test_heap_writes_are_not_structural_changes
    hash = {limit: 19}
    saved = RubyVM.mutation_epoch
    hash[:limit] = 23
    assert_equal saved, RubyVM.mutation_epoch
  end

  def test_deprecated_removal_is_visible_before_warning_reentry
    assert_separately([], <<~'RUBY')
      mod = Module.new
      mod.const_set(:Target, 19)
      mod.deprecate_constant(:Target)
      observations = []
      reader = RubyVM.method(:mutation_epoch)
      saved = nil
      Warning.define_singleton_method(:warn) do |*, **|
        observations << [mod.const_defined?(:Target, false), reader.call != saved]
      end
      Warning[:deprecated] = true
      saved = reader.call
      mod.send(:remove_const, :Target)
      assert_equal [[false, true]], observations
    RUBY
  end
end
