/* Experimental per-CME alternative. The registry does not retain tokens.
 * Single-Ractor/GVL experiment; no refinement or Box contract. */
typedef struct epoch_method_token {
    VALUE cme, klass;
    bool valid;
    struct epoch_method_token *prev, *next;
} epoch_method_token;
static st_table *epoch_token_table;
static VALUE epoch_token_class;
static bool epoch_tokens_disabled;

void
rb_vm_epoch_tokens_disable(void)
{
    /* Set before other Ractors can run, and never reset, including at fork. */
    epoch_tokens_disabled = true;
}

void
rb_vm_epoch_token_revoke(const rb_callable_method_entry_t *cme)
{
    if (epoch_tokens_disabled) return;
    st_data_t key = (st_data_t)cme, head;
    if (epoch_token_table && st_delete(epoch_token_table, &key, &head)) {
        for (epoch_method_token *p = (void *)head; p; p = p->next) p->valid = false;
    }
}

static void
epoch_token_mark(void *ptr)
{
    epoch_method_token *p = ptr;
    /* Pin both references: the registry is keyed by the CME address. */
    rb_gc_mark(p->cme);
    rb_gc_mark(p->klass);
}

static int
epoch_token_replace_head(st_data_t *key, st_data_t *value, st_data_t head, int existing)
{
    if (!existing) return ST_STOP;
    *value = head;
    return ST_CONTINUE;
}

static void
epoch_token_free(void *ptr)
{
    epoch_method_token *p = ptr;
    if (p->valid) {
        if (p->prev) p->prev->next = p->next;
        else {
            st_data_t key = p->cme;
            /* st_insert may allocate even when replacing an existing key. */
            if (p->next) st_update(epoch_token_table, key, epoch_token_replace_head, (st_data_t)p->next);
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
    if (epoch_tokens_disabled) return Qnil;
    Check_Type(klass, T_CLASS);
    const rb_callable_method_entry_t *cme = rb_callable_method_entry(klass, mid);
    if (!cme || cme->def->type == VM_METHOD_TYPE_REFINED) return Qnil;
    epoch_method_token *p;
    VALUE token = TypedData_Make_Struct(epoch_token_class, epoch_method_token, &epoch_token_type, p);
    p->cme = (VALUE)cme;
    p->klass = klass;
    st_data_t head;
    if (!epoch_token_table) epoch_token_table = st_init_numtable();
    if (st_lookup(epoch_token_table, p->cme, &head)) {
        /* Do not allocate after borrowing the existing list head: GC may
         * collect it. Updating an existing entry with st_update cannot grow. */
        p->next = (void *)head;
        p->next->prev = p;
        st_update(epoch_token_table, p->cme, epoch_token_replace_head, (st_data_t)p);
    }
    else {
        st_insert(epoch_token_table, p->cme, (st_data_t)p);
    }
    /* Only registered nodes may unlink themselves. If registration raises,
     * this zero-initialized flag is still false. */
    p->valid = true;
    return token;
}

int
rb_vm_method_token_valid_p(VALUE token)
{
    if (epoch_tokens_disabled) return false;
    epoch_method_token *p;
    TypedData_Get_Struct(token, epoch_method_token, &epoch_token_type, p);
    return p->valid;
}

/*
 *  Document-method: RubyVM.method_token
 *  call-seq:
 *    RubyVM.method_token(klass, name) -> RubyVM::MethodToken or nil
 *
 *  Returns an experimental token for method lookup on +klass+ by +name+.
 *  +klass+ must be a Class, including an existing singleton class; +name+
 *  is a Symbol or String. Does not call the target or +method_missing+.
 *  Returns +nil+ for a missing or refined method entry, or after the process
 *  enters multi-Ractor mode, even if the other Ractors have terminated or
 *  the process subsequently forks. Name conversion uses ordinary Ruby
 *  coercion and may invoke Ruby code.
 *
 *  The token retains its class and method entry until it is collected.
 *  It does not track methods called by the target, including +super+.
 *  Consumers must validate the original method and separately guard the
 *  actual receiver class, lexical scope and mutable values. Check again
 *  after any Ruby execution that may change an assumption.
 *
 *  This API is for MRI prototyping and research only. Its compatibility
 *  is not guaranteed. No refinement, Box or concurrent-Ractor contract
 *  is provided. The Ruby methods themselves can be overridden.
 */
static VALUE
vm_method_token(VALUE self, VALUE klass, VALUE name)
{
    return rb_vm_method_token(klass, rb_to_id(name));
}

/*
 *  Document-method: RubyVM::MethodToken#valid?
 *  call-seq:
 *    token.valid? -> true or false
 *
 *  Returns whether this method-lookup token has not been invalidated.
 *  Revocation is permanent and may be conservative. Revalidate the lookup
 *  before acquiring a replacement token; a token does not prove that the
 *  method has any particular definition or result.
 *
 *  Returns +false+ after the process enters multi-Ractor mode. A successful
 *  check does not lock an assumption across later Ruby calls or thread
 *  switches. For a valid token argument, the C check allocates nothing and
 *  executes no Ruby callback.
 */
static VALUE
vm_method_token_valid(VALUE token)
{
    return RBOOL(rb_vm_method_token_valid_p(token));
}

static void
Init_epoch_token(void)
{
    /*
     * Document-class: RubyVM::MethodToken
     *
     * An experimental, opaque method-lookup assumption for MRI research.
     * Obtain tokens with RubyVM.method_token, not with ::new. Tokens are
     * usable only before the process enters multi-Ractor mode.
     */
    epoch_token_class = rb_define_class_under(rb_cRubyVM, "MethodToken", rb_cObject);
    rb_global_variable(&epoch_token_class);
    rb_undef_alloc_func(epoch_token_class);
    rb_define_method(epoch_token_class, "valid?", vm_method_token_valid, 0);
    rb_define_singleton_method(rb_cRubyVM, "method_token", vm_method_token, 2);
}
