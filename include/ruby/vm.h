#ifndef RUBY_VM_H                                    /*-*-C++-*-vi:se ft=cpp:*/
#define RUBY_VM_H 1
/**
 * @file
 * @author     $Author$
 * @date       Sat May 31 15:17:36 2008
 * @copyright  Copyright (C) 2008 Yukihiro Matsumoto
 * @copyright  This  file  is   a  part  of  the   programming  language  Ruby.
 *             Permission  is hereby  granted,  to  either redistribute  and/or
 *             modify this file, provided that  the conditions mentioned in the
 *             file COPYING are met.  Consult the file for details.
 *
 * We  planned to  have multiple  VMs  run side-by-side.   The API  here was  a
 * preparation of that feature.  The topic branch was eventually abandoned, and
 * we now have Ractor.  This file is kind of obsolescent.
 */
#include "ruby/internal/dllexport.h"
#include "ruby/internal/stdbool.h"
#include "ruby/internal/value.h"

RBIMPL_SYMBOL_EXPORT_BEGIN()

/**
 * The opaque struct to hold VM internals.  Its fields are intentionally hidden
 * from extension libraries because it changes drastically time to time.
 */
typedef struct rb_vm_struct ruby_vm_t;

/**
 * Destructs the  passed VM.   You don't  have to call  this API  directly now,
 * because there is  no way to create one.   There is only one VM  at one time.
 * ruby_stop() should just suffice.
 */
int ruby_vm_destruct(ruby_vm_t *vm);

/**
 * ruby_vm_at_exit registers a function _func_ to be invoked when a VM
 * passed away.  Functions registered this way runs in reverse order
 * of registration, just like END {} block does.  The difference is
 * its timing to be triggered. ruby_vm_at_exit functions runs when a
 * VM _passed_ _away_, while END {} blocks runs just _before_ a VM
 * _is_ _passing_ _away_.
 *
 * You cannot register a function to another VM than where you are in.
 * So where to register is intuitive, omitted.  OTOH the argument
 * _func_ cannot know which VM it is in because at the time of
 * invocation, the VM has already died and there is no execution
 * context.  The VM itself is passed as the first argument to it.
 *
 * @param[in] func the function to register.
 */
void ruby_vm_at_exit(void(*func)(ruby_vm_t *));

/**
 * Returns whether the Ruby VM will free all memory at shutdown.
 *
 * @return true if free-at-exit is enabled, false otherwise.
 */
bool ruby_free_at_exit_p(void);

/**
 * Experimental lookup assumption for a Class (including singleton classes).
 * Returns nil for missing/refined entries, with Ruby Box enabled, or outside
 * single-main-Ractor execution. Does not invoke the target or method_missing.
 * Requires the GVL. Raises TypeError for a non-Class argument.
 *
 * The token is an internal VM object: NEVER expose it to Ruby, even in an
 * Array. Retain it in C and mark with rb_gc_mark(), or rb_gc_mark_movable()
 * plus rb_gc_location(); use RB_OBJ_WRITE() when storing in a Ruby object.
 * It retains neither klass nor the method entry. GC conservatively revokes
 * it when either is collected; a revoked token remains safe to check.
 * It cannot be shared between Ractors.
 * It covers lookup only, not callees/super, receiver identity, lexical
 * refinements or mutable data. Certify the original definition separately.
 * No compatibility guarantee is provided for this experimental C API.
 */
VALUE rb_vm_method_token(VALUE klass, ID mid);

/**
 * Check a token returned above. Requires the GVL. Raises TypeError for nil
 * or another object. A genuine token check allocates nothing and invokes no
 * Ruby callback; invalidation is permanent and conservative.
 * Returns false outside single-main-Ractor execution or with Ruby Box enabled.
 * After fork, the child's normal call-cache state applies; a revoked cache
 * never revives, but an unchanged cache may become usable again. A successful
 * check is not a lock across Ruby execution or
 * thread switches: check again at every relevant reentry boundary.
 */
int rb_vm_method_token_valid_p(VALUE token);

RBIMPL_SYMBOL_EXPORT_END()

#endif /* RUBY_VM_H */
