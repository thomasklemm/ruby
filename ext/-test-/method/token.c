#include "ruby.h"
#include "ruby/vm.h"

static void
method_token_mark(void *ptr)
{
    rb_gc_mark_movable(*(VALUE *)ptr);
}

static void
method_token_compact(void *ptr)
{
    *(VALUE *)ptr = rb_gc_location(*(VALUE *)ptr);
}

static const rb_data_type_t method_token_type = {
    "Bug::Method::Token",
    {method_token_mark, RUBY_TYPED_DEFAULT_FREE, NULL, method_token_compact},
    0, 0, RUBY_TYPED_FREE_IMMEDIATELY | RUBY_TYPED_WB_PROTECTED
};

static VALUE
method_token(VALUE self, VALUE klass, VALUE name)
{
    VALUE *ptr;
    VALUE obj = TypedData_Make_Struct(rb_cObject, VALUE, &method_token_type, ptr);
    VALUE token = rb_vm_method_token(klass, rb_to_id(name));
    if (NIL_P(token)) return Qnil;
    RB_OBJ_WRITE(obj, ptr, token);
    return obj;
}

static VALUE
method_token_valid(VALUE self, VALUE token)
{
    if (rb_typeddata_is_kind_of(token, &method_token_type)) {
        token = *(VALUE *)rb_check_typeddata(token, &method_token_type);
    }
    return rb_vm_method_token_valid_p(token) ? Qtrue : Qfalse;
}

void
Init_token(VALUE mod)
{
    rb_define_module_function(mod, "token", method_token, 2);
    rb_define_module_function(mod, "token_valid?", method_token_valid, 1);
}
