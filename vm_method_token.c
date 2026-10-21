/* Experimental per-CME alternative. No Ruby callbacks in revocation, no retained
 * token roots: the native registry is unlinked when a token is collected.
 * Same-Ractor/GVL experiment; no refinement or Box contract. */
typedef struct epoch_method_token {
    VALUE cme, klass;
    bool valid;
    struct epoch_method_token *prev, *next;
} epoch_method_token;
static st_table *epoch_token_table;
static VALUE epoch_token_class;

void
rb_vm_epoch_token_revoke(const rb_callable_method_entry_t *cme)
{
    if (!rb_ractor_main_p()) return;
    st_data_t key = (st_data_t)cme, head;
    if (epoch_token_table && st_delete(epoch_token_table, &key, &head)) {
        for (epoch_method_token *p = (void *)head; p; p = p->next) p->valid = false;
    }
}

static void
epoch_token_mark(void *ptr)
{
    epoch_method_token *p = ptr;
    rb_gc_mark(p->cme);
    rb_gc_mark(p->klass);
}

static void
epoch_token_free(void *ptr)
{
    epoch_method_token *p = ptr;
    if (p->valid) {
        if (p->prev) p->prev->next = p->next;
        else {
            st_data_t key = p->cme;
            if (p->next) st_insert(epoch_token_table, key, (st_data_t)p->next);
            else st_delete(epoch_token_table, &key, NULL);
        }
        if (p->next) p->next->prev = p->prev;
    }
    xfree(p);
}

static const rb_data_type_t epoch_token_type = {
    "experimental method token",
    {epoch_token_mark, epoch_token_free, NULL},
    NULL, NULL, RUBY_TYPED_FREE_IMMEDIATELY
};

VALUE
rb_vm_method_token(VALUE klass, ID mid)
{
    if (!rb_ractor_main_p()) return Qnil;
    Check_Type(klass, T_CLASS);
    const rb_callable_method_entry_t *cme = rb_callable_method_entry(klass, mid);
    if (!cme || cme->def->type == VM_METHOD_TYPE_REFINED) return Qnil;
    epoch_method_token *p;
    VALUE token = TypedData_Make_Struct(epoch_token_class, epoch_method_token, &epoch_token_type, p);
    p->cme = (VALUE)cme;
    p->klass = klass;
    p->valid = true;
    st_data_t head;
    if (!epoch_token_table) epoch_token_table = st_init_numtable();
    if (st_lookup(epoch_token_table, p->cme, &head)) {
        p->next = (void *)head;
        p->next->prev = p;
    }
    st_insert(epoch_token_table, p->cme, (st_data_t)p);
    return token;
}

int
rb_vm_method_token_valid_p(VALUE token)
{
    if (!rb_ractor_main_p()) return false;
    epoch_method_token *p;
    TypedData_Get_Struct(token, epoch_method_token, &epoch_token_type, p);
    return p->valid;
}

static VALUE
vm_method_token(VALUE self, VALUE klass, VALUE name)
{
    return rb_vm_method_token(klass, rb_to_id(name));
}

static VALUE
vm_method_token_valid(VALUE token)
{
    return RBOOL(rb_vm_method_token_valid_p(token));
}

static void
Init_epoch_token(void)
{
    epoch_token_class = rb_define_class_under(rb_cRubyVM, "MethodToken", rb_cObject);
    rb_global_variable(&epoch_token_class);
    rb_undef_alloc_func(epoch_token_class);
    rb_define_method(epoch_token_class, "valid?", vm_method_token_valid, 0);
    rb_define_singleton_method(rb_cRubyVM, "method_token", vm_method_token, 2);
}
