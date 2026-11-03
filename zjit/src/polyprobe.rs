//! Throwaway polymorphism probe (not for upstream).
//!
//! ZJIT_POLYPROBE=interp:PATH  profile every send/getivar/invokeblock execution forever
//!                             (run with a huge --zjit-call-threshold so nothing compiles)
//! ZJIT_POLYPROBE=jit:PATH     record the receiver type of every dynamic fallback
//! RubyVM::ZJIT.reset_stats! clears the probe; RubyVM::ZJIT.stats writes PATH (TSV).

use std::collections::HashMap;
use std::io::Write;
use crate::cruby::*;

pub struct Probe {
    pub interp: bool,
    path: String,
    // (iseq, insn_idx, kind) -> type -> count
    sites: HashMap<(usize, u32, &'static str), HashMap<(usize, u32), u64>>,
    site_labels: HashMap<(usize, u32), String>,
    type_labels: HashMap<(usize, u32), String>,
    kinds: HashMap<String, &'static str>,
}

static mut PROBE: Option<Probe> = None;
static mut INIT: bool = false;

#[allow(static_mut_refs)]
pub fn probe() -> Option<&'static mut Probe> {
    unsafe {
        if !INIT {
            INIT = true;
            if let Ok(v) = std::env::var("ZJIT_POLYPROBE") {
                if let Some((mode, path)) = v.split_once(':') {
                    PROBE = Some(Probe { interp: mode == "interp", path: path.to_string(),
                        sites: HashMap::new(), site_labels: HashMap::new(), type_labels: HashMap::new(), kinds: HashMap::new() });
                }
            }
        }
        PROBE.as_mut()
    }
}

pub fn interp_enabled() -> bool { probe().is_some_and(|p| p.interp) }
pub fn jit_enabled() -> bool { probe().is_some_and(|p| !p.interp) }

fn label_site(iseq: IseqPtr, insn_idx: u32, what: &str) -> String {
    format!("{}\t{}", iseq_get_location(iseq, insn_idx), what)
}

fn class_label(klass: VALUE) -> String {
    if klass.is_singleton_class() {
        unsafe extern "C" { fn rb_class_attached_object(klass: VALUE) -> VALUE; }
        let attached = unsafe { rb_class_attached_object(klass) };
        if unsafe { RB_TYPE_P(attached, RUBY_T_CLASS) || RB_TYPE_P(attached, RUBY_T_MODULE) } {
            format!("#<Class:{}>", get_class_name(attached))
        } else {
            format!("singleton:obj({})", get_class_name(unsafe { rb_class_real(klass) }))
        }
    } else { get_class_name(klass) }
}

fn label_recv(obj: VALUE) -> (usize, u32, String) {
    if obj.special_const_p() {
        let klass = obj.class_of();
        return (klass.0, u32::MAX, get_class_name(klass));
    }
    let klass = obj.class_of();
    let shape = obj.shape_id_of().0;
    let name = class_label(klass);
    (klass.0, shape, name)
}

fn label_block(bh: VALUE) -> (usize, u32, String) {
    unsafe {
        if bh == Qnil || bh.0 == 0 { return (0, 0, "<none>".into()); }
        if bh.special_const_p() {
            if bh.static_sym_p() { return (bh.0, 1, format!(":{}", ruby_sym_to_rust_string(bh))); }
            return (bh.0, 1, "<special>".into());
        }
        if rb_IMEMO_TYPE_P(bh, imemo_iseq) == 1 {
            let iseq = bh.0 as IseqPtr;
            return (bh.0, 2, format!("iseq:{}", iseq_get_location(iseq, 0)));
        }
        if rb_IMEMO_TYPE_P(bh, imemo_ifunc) == 1 { return (1, 3, "<ifunc>".into()); }
        if rb_obj_is_proc(bh).test() { return (2, 4, "<proc>".into()); }
        if RB_TYPE_P(bh, RUBY_T_SYMBOL) { return (bh.0, 1, format!(":{}", ruby_sym_to_rust_string(bh))); }
        (3, 5, "<other>".into())
    }
}

impl Probe {
    fn record(&mut self, iseq: IseqPtr, insn_idx: u32, kind: &'static str, what: impl FnOnce() -> String,
              ty: (usize, u32, String)) {
        let site = (iseq as usize, insn_idx);
        self.site_labels.entry(site).or_insert_with(|| label_site(iseq, insn_idx, &what()));
        let tkey = (ty.0, ty.1);
        self.type_labels.entry(tkey).or_insert(ty.2);
        *self.sites.entry((site.0, site.1, kind)).or_default().entry(tkey).or_insert(0) += 1;
    }

    pub fn reset(&mut self) { self.sites.clear(); }

    pub fn dump(&self) {
        let Ok(mut f) = std::fs::File::create(&self.path) else { return };
        for ((iseq, idx, kind), types) in &self.sites {
            let site = &self.site_labels[&(*iseq, *idx)];
            for ((k, shape), n) in types {
                let tl = &self.type_labels[&(*k, *shape)];
                let _ = writeln!(f, "{kind}\t{iseq:x}:{idx}\t{site}\t{tl}\t{shape}\t{n}");
            }
        }
    }
}

/// Interpreter-mode recording from the profiler.
pub fn record_interp(opcode: ruby_vminsn_type, iseq: IseqPtr, insn_idx: u32, cfp: CfpPtr, pc: *const VALUE) {
    let Some(p) = probe() else { return };
    unsafe {
        let opnd = |i: usize| pc.add(1 + i).read();
        match opcode {
            YARVINSN_opt_send_without_block | YARVINSN_send => {
                let cd: *const rb_call_data = opnd(0).as_ptr();
                let argc = crate::profile::num_arguments_on_stack(cd);
                let recv = *get_cfp_sp(cfp).offset(-1 - argc as isize);
                p.record(iseq, insn_idx, "send", || ruby_call_method_name(cd), label_recv(recv));
                let mid = ruby_call_method_id(cd);
                let cme = rb_callable_method_entry(recv.class_of(), mid);
                let ty = if cme.is_null() { (0, 0, "<none>".to_string()) } else {
                    (cme as usize, 0, format!("{}#{}", class_label((*cme).owner), mid.contents_lossy()))
                };
                p.record(iseq, insn_idx, "send_cme", || ruby_call_method_name(cd), ty);
            }
            YARVINSN_opt_plus | YARVINSN_opt_minus | YARVINSN_opt_mult | YARVINSN_opt_div | YARVINSN_opt_mod
            | YARVINSN_opt_eq | YARVINSN_opt_neq | YARVINSN_opt_lt | YARVINSN_opt_le | YARVINSN_opt_gt | YARVINSN_opt_ge
            | YARVINSN_opt_and | YARVINSN_opt_or | YARVINSN_opt_aref | YARVINSN_opt_ltlt | YARVINSN_opt_regexpmatch2
            | YARVINSN_opt_aset | YARVINSN_opt_nil_p | YARVINSN_opt_empty_p | YARVINSN_opt_not | YARVINSN_opt_length
            | YARVINSN_opt_size | YARVINSN_opt_succ => {
                let n: isize = match opcode {
                    YARVINSN_opt_aset => 3,
                    YARVINSN_opt_nil_p | YARVINSN_opt_empty_p | YARVINSN_opt_not | YARVINSN_opt_length
                    | YARVINSN_opt_size | YARVINSN_opt_succ => 1,
                    _ => 2,
                };
                let cd: *const rb_call_data = opnd(0).as_ptr();
                let recv = *get_cfp_sp(cfp).offset(-n);
                p.record(iseq, insn_idx, "send", || ruby_call_method_name(cd), label_recv(recv));
                let mid = ruby_call_method_id(cd);
                let cme = rb_callable_method_entry(recv.class_of(), mid);
                let ty = if cme.is_null() { (0, 0, "<none>".to_string()) } else {
                    (cme as usize, 0, format!("{}#{}", class_label((*cme).owner), mid.contents_lossy()))
                };
                p.record(iseq, insn_idx, "send_cme", || ruby_call_method_name(cd), ty);
            }
            YARVINSN_getinstancevariable => {
                let id = ID(opnd(0).0 as u64);
                let recv = rb_get_cfp_self(cfp);
                p.record(iseq, insn_idx, "getivar", || id.contents_lossy().to_string(), label_recv(recv));
                let ty = if recv.special_const_p() { (0, 0, "immediate".to_string()) } else {
                    let shape = recv.shape_id_of();
                    let mut idx: attr_index_t = 0;
                    let layout = match shape.layout() { ShapeLayout::RObject => "RObject", ShapeLayout::RClass => "RClass", ShapeLayout::Extended => "Extended", ShapeLayout::Other => "Other" };
                    if shape.is_complex() { (1, 0, format!("complex/{layout}")) }
                    else if rb_shape_get_iv_index(shape.0, id, &mut idx) { (2 + idx as usize, shape.layout() as u32, format!("idx={idx}/{layout}")) }
                    else { (1, 1, format!("undefined/{layout}")) }
                };
                p.record(iseq, insn_idx, "getivar_idx", || id.contents_lossy().to_string(), ty);
            }
            YARVINSN_invokeblock => {
                let bh = rb_vm_get_untagged_block_handler(cfp);
                p.record(iseq, insn_idx, "invokeblock", || "yield".into(), label_block(bh));
            }
            _ => {}
        }
    }
}

/// JIT-mode recording at a dynamic fallback. Called after the fallback's frame state is written.
#[unsafe(no_mangle)]
pub extern "C" fn rb_zjit_polyprobe_fallback(cfp: CfpPtr, iseq: IseqPtr, insn_idx: u32, reason: *const std::ffi::c_char, cd: *const rb_call_data, recv_or_zero: VALUE) {
    let Some(p) = probe() else { return };
    let reason: &'static str = unsafe { std::ffi::CStr::from_ptr(reason).to_str().unwrap_or("?") };
    // Only polymorphism-related reasons; other paths (e.g. `...` forwarding) have a different stack layout.
    if !matches!(reason, "Send: polymorphic fallback" | "Send: polymorphic call site" | "Send: megamorphic call site"
        | "InvokeBlock: polymorphic dispatch miss" | "InvokeBlock: not yet specialized") && !reason.starts_with("getivar") {
        return;
    }
    unsafe {
        if reason.starts_with("InvokeBlock") {
            let bh = rb_vm_get_untagged_block_handler(cfp);
            p.record(iseq, insn_idx, reason, || "yield".into(), label_block(bh));
        } else if reason.starts_with("getivar") {
            p.record(iseq, insn_idx, reason, || "ivar".into(), label_recv(recv_or_zero));
        } else if !cd.is_null() {
            let argc = crate::profile::num_arguments_on_stack(cd);
            let recv = *get_cfp_sp(cfp).offset(-1 - argc as isize);
            p.record(iseq, insn_idx, reason, || ruby_call_method_name(cd), label_recv(recv));
            let mid = ruby_call_method_id(cd);
            let cme = rb_callable_method_entry(recv.class_of(), mid);
            let ty = if cme.is_null() { (0, 0, "<none>".to_string()) } else {
                (cme as usize, 0, format!("{}#{}", class_label((*cme).owner), mid.contents_lossy()))
            };
            let kind: &'static str = match p.kinds.get(reason) { Some(k) => k, None => {
                let k: &'static str = Box::leak(format!("{reason}/cme").into_boxed_str());
                p.kinds.insert(reason.to_string(), k); k } };
            p.record(iseq, insn_idx, kind, || ruby_call_method_name(cd), ty);
        }
    }
}

/// Name of the getivar fallback counter emitted just before the next GetIvar in codegen.
pub static mut LAST_GETIVAR_REASON: Option<&'static str> = None;
