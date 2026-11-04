// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Syntax facts only: syn removes comments/literals from the attribute tree.
// This does not expand macros, resolve modules, or discharge proof obligations.
use std::{collections::HashSet, env, fs, process::ExitCode};
use syn::{
    parse::Parser, punctuated::Punctuated, spanned::Spanned, visit::Visit, Attribute, Meta, Token,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Active {
    Yes,
    No,
    Unknown,
}
impl Active {
    fn and(self, other: Self) -> Self {
        match (self, other) {
            (Self::No, _) | (_, Self::No) => Self::No,
            (Self::Yes, Self::Yes) => Self::Yes,
            _ => Self::Unknown,
        }
    }
    fn not(self) -> Self {
        match self {
            Self::Yes => Self::No,
            Self::No => Self::Yes,
            Self::Unknown => Self::Unknown,
        }
    }
}

fn parts(meta: &Meta) -> syn::Result<Vec<Meta>> {
    let Meta::List(list) = meta else {
        return Err(syn::Error::new(meta.span(), "expected attribute arguments"));
    };
    Ok(Punctuated::<Meta, Token![,]>::parse_terminated
        .parse2(list.tokens.clone())?
        .into_iter()
        .collect())
}

// Only facts independent of target/features are evaluated. Unknown conditions
// on proof declarations are unavailable, never guessed active or inactive.
fn condition(meta: &Meta) -> syn::Result<Active> {
    if matches!(meta, Meta::Path(path) if path.is_ident("creusot")) {
        return Ok(Active::Yes);
    }
    if matches!(meta, Meta::Path(path) if path.is_ident("test")) {
        return Ok(Active::No);
    }
    if meta.path().is_ident("not") {
        let values = parts(meta)?;
        if values.len() != 1 {
            return Err(syn::Error::new(meta.span(), "not requires one condition"));
        }
        return condition(&values[0]).map(Active::not);
    }
    if meta.path().is_ident("all") || meta.path().is_ident("any") {
        let any = meta.path().is_ident("any");
        let mut result = Active::Yes;
        for value in parts(meta)? {
            let value = condition(&value)?;
            result = result.and(if any { value.not() } else { value });
        }
        return Ok(if any { result.not() } else { result });
    }
    Ok(Active::Unknown)
}

fn expand(
    meta: &Meta,
    active: Active,
    result: &mut Vec<(Meta, Active)>,
    depth: usize,
) -> syn::Result<()> {
    if depth > 64 {
        return Err(syn::Error::new(
            meta.span(),
            "cfg_attr nesting exceeds inspection bound",
        ));
    }
    if meta.path().is_ident("cfg_attr") {
        let values = parts(meta)?;
        let Some((predicate, attributes)) = values.split_first() else {
            return Err(syn::Error::new(meta.span(), "cfg_attr has no condition"));
        };
        let active = active.and(condition(predicate)?);
        for attribute in attributes {
            expand(attribute, active, result, depth + 1)?;
        }
    } else {
        result.push((meta.clone(), active));
    }
    Ok(())
}

fn expanded(attributes: &[Attribute]) -> syn::Result<Vec<(Meta, Active)>> {
    let mut result = Vec::new();
    for attribute in attributes {
        expand(&attribute.meta, Active::Yes, &mut result, 0)?;
    }
    Ok(result)
}

fn scope(attributes: &[Attribute], parent: Active) -> syn::Result<Active> {
    let mut active = parent;
    for (meta, included) in expanded(attributes)? {
        if !meta.path().is_ident("cfg") || included == Active::No {
            continue;
        }
        let values = parts(&meta)?;
        if values.len() != 1 {
            return Err(syn::Error::new(meta.span(), "cfg requires one condition"));
        }
        let value = condition(&values[0])?;
        active = active.and(if included == Active::Yes || value == Active::Yes {
            value
        } else {
            Active::Unknown
        });
    }
    Ok(active)
}

fn proof_name(meta: &Meta) -> Option<String> {
    let names: Vec<String> = meta
        .path()
        .segments
        .iter()
        .map(|part| part.ident.to_string())
        .collect();
    let allowed_path = names.len() == 1
        || (names.len() == 2 && matches!(names[0].as_str(), "creusot" | "creusot_contracts"))
        || (names.len() == 3 && names[0] == "creusot_std" && names[1] == "macros");
    let name = names.last()?;
    if allowed_path
        && matches!(
            name.as_str(),
            "requires"
                | "ensures"
                | "trusted"
                | "invariant"
                | "variant"
                | "logic"
                | "law"
                | "open"
                | "predicate"
                | "terminates"
                | "pure"
        )
    {
        Some(name.clone())
    } else {
        None
    }
}

struct Facts {
    active: Active,
    seen: HashSet<(usize, usize)>,
    rows: Vec<(&'static str, usize)>,
    error: Option<syn::Error>,
}
impl Facts {
    fn attributes(&mut self, attributes: &[Attribute], function: bool) {
        for attribute in attributes {
            let start = attribute.span().start();
            if !self.seen.insert((start.line, start.column)) {
                continue;
            }
            let mut items = Vec::new();
            if let Err(error) = expand(&attribute.meta, self.active, &mut items, 0) {
                self.error = Some(error);
                continue;
            }
            for (meta, active) in items {
                let Some(name) = proof_name(&meta) else {
                    continue;
                };
                if active == Active::No {
                    continue;
                }
                if active == Active::Unknown {
                    self.error = Some(syn::Error::new(
                        meta.span(),
                        "proof attribute has an unresolved cfg condition",
                    ));
                    continue;
                }
                let kind = match name.as_str() {
                    "requires" | "ensures" if function && matches!(meta, Meta::List(_)) => {
                        "contract"
                    }
                    "trusted" if function => "trusted",
                    "requires" | "ensures" | "trusted" => {
                        self.error = Some(syn::Error::new(
                            meta.span(),
                            "contract/trusted attribute is not bound to a supported function",
                        ));
                        continue;
                    }
                    _ => "obligation",
                };
                self.rows.push((kind, meta.span().start().line));
            }
        }
    }
    fn enter(&mut self, attributes: &[Attribute]) -> Active {
        let previous = self.active;
        match scope(attributes, previous) {
            Ok(active) => self.active = active,
            Err(error) => self.error = Some(error),
        }
        previous
    }
}

macro_rules! visit_scope {
    ($method:ident, $node:ty, $function:expr) => {
        fn $method(&mut self, node: &'ast $node) {
            let previous = self.enter(&node.attrs);
            self.attributes(&node.attrs, $function);
            syn::visit::$method(self, node);
            self.active = previous;
        }
    };
}
impl<'ast> Visit<'ast> for Facts {
    // Every attributed node in pinned syn 2.0.119 propagates its cfg scope.
    // Functions may occur inside consts, local initializers and expressions,
    // not only modules. Recheck this inventory when changing the parser pin.
    visit_scope!(visit_arm, syn::Arm, false);
    visit_scope!(visit_bare_fn_arg, syn::BareFnArg, false);
    visit_scope!(visit_bare_variadic, syn::BareVariadic, false);
    visit_scope!(visit_const_param, syn::ConstParam, false);
    visit_scope!(visit_derive_input, syn::DeriveInput, false);
    visit_scope!(visit_expr_array, syn::ExprArray, false);
    visit_scope!(visit_expr_assign, syn::ExprAssign, false);
    visit_scope!(visit_expr_async, syn::ExprAsync, false);
    visit_scope!(visit_expr_await, syn::ExprAwait, false);
    visit_scope!(visit_expr_binary, syn::ExprBinary, false);
    visit_scope!(visit_expr_block, syn::ExprBlock, false);
    visit_scope!(visit_expr_break, syn::ExprBreak, false);
    visit_scope!(visit_expr_call, syn::ExprCall, false);
    visit_scope!(visit_expr_cast, syn::ExprCast, false);
    visit_scope!(visit_expr_closure, syn::ExprClosure, false);
    visit_scope!(visit_expr_const, syn::ExprConst, false);
    visit_scope!(visit_expr_continue, syn::ExprContinue, false);
    visit_scope!(visit_expr_field, syn::ExprField, false);
    visit_scope!(visit_expr_for_loop, syn::ExprForLoop, false);
    visit_scope!(visit_expr_group, syn::ExprGroup, false);
    visit_scope!(visit_expr_if, syn::ExprIf, false);
    visit_scope!(visit_expr_index, syn::ExprIndex, false);
    visit_scope!(visit_expr_infer, syn::ExprInfer, false);
    visit_scope!(visit_expr_let, syn::ExprLet, false);
    visit_scope!(visit_expr_lit, syn::ExprLit, false);
    visit_scope!(visit_expr_loop, syn::ExprLoop, false);
    visit_scope!(visit_expr_macro, syn::ExprMacro, false);
    visit_scope!(visit_expr_match, syn::ExprMatch, false);
    visit_scope!(visit_expr_method_call, syn::ExprMethodCall, false);
    visit_scope!(visit_expr_paren, syn::ExprParen, false);
    visit_scope!(visit_expr_path, syn::ExprPath, false);
    visit_scope!(visit_expr_range, syn::ExprRange, false);
    visit_scope!(visit_expr_raw_addr, syn::ExprRawAddr, false);
    visit_scope!(visit_expr_reference, syn::ExprReference, false);
    visit_scope!(visit_expr_repeat, syn::ExprRepeat, false);
    visit_scope!(visit_expr_return, syn::ExprReturn, false);
    visit_scope!(visit_expr_struct, syn::ExprStruct, false);
    visit_scope!(visit_expr_try, syn::ExprTry, false);
    visit_scope!(visit_expr_try_block, syn::ExprTryBlock, false);
    visit_scope!(visit_expr_tuple, syn::ExprTuple, false);
    visit_scope!(visit_expr_unary, syn::ExprUnary, false);
    visit_scope!(visit_expr_unsafe, syn::ExprUnsafe, false);
    visit_scope!(visit_expr_while, syn::ExprWhile, false);
    visit_scope!(visit_expr_yield, syn::ExprYield, false);
    visit_scope!(visit_field, syn::Field, false);
    visit_scope!(visit_field_pat, syn::FieldPat, false);
    visit_scope!(visit_field_value, syn::FieldValue, false);
    visit_scope!(visit_file, syn::File, false);
    visit_scope!(visit_foreign_item_fn, syn::ForeignItemFn, true);
    visit_scope!(visit_foreign_item_macro, syn::ForeignItemMacro, false);
    visit_scope!(visit_foreign_item_static, syn::ForeignItemStatic, false);
    visit_scope!(visit_foreign_item_type, syn::ForeignItemType, false);
    visit_scope!(visit_impl_item_const, syn::ImplItemConst, false);
    visit_scope!(visit_impl_item_fn, syn::ImplItemFn, true);
    visit_scope!(visit_impl_item_macro, syn::ImplItemMacro, false);
    visit_scope!(visit_impl_item_type, syn::ImplItemType, false);
    visit_scope!(visit_item_const, syn::ItemConst, false);
    visit_scope!(visit_item_enum, syn::ItemEnum, false);
    visit_scope!(visit_item_extern_crate, syn::ItemExternCrate, false);
    visit_scope!(visit_item_fn, syn::ItemFn, true);
    visit_scope!(visit_item_foreign_mod, syn::ItemForeignMod, false);
    visit_scope!(visit_item_impl, syn::ItemImpl, false);
    visit_scope!(visit_item_macro, syn::ItemMacro, false);
    visit_scope!(visit_item_mod, syn::ItemMod, false);
    visit_scope!(visit_item_static, syn::ItemStatic, false);
    visit_scope!(visit_item_struct, syn::ItemStruct, false);
    visit_scope!(visit_item_trait, syn::ItemTrait, false);
    visit_scope!(visit_item_trait_alias, syn::ItemTraitAlias, false);
    visit_scope!(visit_item_type, syn::ItemType, false);
    visit_scope!(visit_item_union, syn::ItemUnion, false);
    visit_scope!(visit_item_use, syn::ItemUse, false);
    visit_scope!(visit_lifetime_param, syn::LifetimeParam, false);
    visit_scope!(visit_local, syn::Local, false);
    visit_scope!(visit_pat_ident, syn::PatIdent, false);
    visit_scope!(visit_pat_or, syn::PatOr, false);
    visit_scope!(visit_pat_paren, syn::PatParen, false);
    visit_scope!(visit_pat_reference, syn::PatReference, false);
    visit_scope!(visit_pat_rest, syn::PatRest, false);
    visit_scope!(visit_pat_slice, syn::PatSlice, false);
    visit_scope!(visit_pat_struct, syn::PatStruct, false);
    visit_scope!(visit_pat_tuple, syn::PatTuple, false);
    visit_scope!(visit_pat_tuple_struct, syn::PatTupleStruct, false);
    visit_scope!(visit_pat_type, syn::PatType, false);
    visit_scope!(visit_pat_wild, syn::PatWild, false);
    visit_scope!(visit_receiver, syn::Receiver, false);
    visit_scope!(visit_stmt_macro, syn::StmtMacro, false);
    visit_scope!(visit_trait_item_const, syn::TraitItemConst, false);
    visit_scope!(visit_trait_item_fn, syn::TraitItemFn, true);
    visit_scope!(visit_trait_item_macro, syn::TraitItemMacro, false);
    visit_scope!(visit_trait_item_type, syn::TraitItemType, false);
    visit_scope!(visit_type_param, syn::TypeParam, false);
    visit_scope!(visit_variadic, syn::Variadic, false);
    visit_scope!(visit_variant, syn::Variant, false);
    fn visit_attribute(&mut self, node: &'ast Attribute) {
        self.attributes(std::slice::from_ref(node), false);
    }
    fn visit_macro(&mut self, node: &'ast syn::Macro) {
        if node.path.is_ident("proof_assert") {
            match self.active {
                Active::Yes => self.rows.push(("obligation", node.span().start().line)),
                Active::Unknown => {
                    self.error = Some(syn::Error::new(
                        node.span(),
                        "proof assertion has an unresolved cfg condition",
                    ))
                }
                Active::No => {}
            }
        }
        // Macro bodies are intentionally opaque: a macro definition or a
        // quoted token tree is not an expanded, bound function declaration.
    }
}

fn inspect(source: &str) -> syn::Result<Vec<(&'static str, usize)>> {
    let syntax = syn::parse_file(source)?;
    let mut facts = Facts {
        active: Active::Yes,
        seen: HashSet::new(),
        rows: Vec::new(),
        error: None,
    };
    facts.visit_file(&syntax);
    match facts.error {
        Some(error) => Err(error),
        None => Ok(facts.rows),
    }
}

fn run() -> Result<(), String> {
    let files: Vec<String> = env::args().skip(1).collect();
    if files.is_empty() {
        return Err("no source files supplied".into());
    }
    let mut output = String::new();
    for file in files {
        if file.contains(['\t', '\n', '\r']) {
            return Err("source path contains an unsupported control character".into());
        }
        let source = fs::read_to_string(&file).map_err(|error| format!("{file}: {error}"))?;
        let facts = inspect(&source)
            .map_err(|error| format!("{file}:{}: {error}", error.span().start().line))?;
        for (kind, line) in facts {
            output.push_str(&format!("{kind}\t{file}\t{line}\n"));
        }
    }
    // Emit only a complete inspection: a later parse failure cannot leave a
    // partial count that a shell pipeline could mistake for complete evidence.
    print!("{output}");
    Ok(())
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("creusot-source-facts: NOT INSPECTED: {error}");
            ExitCode::from(2)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::inspect;
    #[test]
    fn conditional_qualified_multiline_contracts_bind_to_functions() {
        let rows = inspect("#[cfg_attr(creusot, creusot_std::macros::ensures(\n result == x\n))]\npub fn id(x: u32) -> u32 { x }\n#[cfg_attr(creusot, creusot_std::macros::trusted)]\nfn oracle() {}\n").expect("valid source");
        assert_eq!(rows, vec![("contract", 1), ("trusted", 5)]);
    }
    #[test]
    fn comments_strings_and_unexpanded_macro_tokens_are_not_attributes() {
        let rows = inspect(
            r####"/* nested /* #[ensures(false)] */ #[trusted] */
// #[ensures(false)]
/// `#[trusted]`
fn text() { let _ = r###"#[ensures(false)]"###; let _ = "#[trusted]"; }
macro_rules! quoted { () => { #[ensures(false)] fn quoted() {} }; }
"####,
        )
        .expect("valid source");
        assert!(rows.is_empty());
    }
    #[test]
    fn inactive_functions_and_inline_modules_are_not_credited() {
        let rows = inspect("#[cfg(not(creusot))] mod native { #[ensures(false)] fn no() {} }\n#[cfg(test)] #[ensures(false)] fn test_only() {}\n#[cfg_attr(not(creusot), ensures(false))] fn other() {}\n").expect("valid source");
        assert!(rows.is_empty());
    }
    #[test]
    fn every_enclosing_item_and_expression_keeps_its_cfg_scope() {
        let sources = [
            "#[cfg(not(creusot))] const _: () = { #[ensures(true)] fn hidden() {} };",
            "#[cfg(not(creusot))] static X: () = { #[ensures(true)] fn hidden() {} };",
            r#"#[cfg(not(creusot))] extern "C" { #[trusted] fn hidden(); }"#,
            "#[cfg(not(creusot))] enum E { V = { #[ensures(true)] fn hidden() {} 0 } }",
            "#[cfg(not(creusot))] struct S<const X: usize = { #[ensures(true)] fn hidden() {} 0 }>;",
            "fn outer() { #[cfg(not(creusot))] let _ = { #[ensures(true)] fn hidden() {} }; }",
            "fn outer() { #[cfg(not(creusot))] if true { #[ensures(true)] fn hidden() {} } }",
            "fn outer() { #[cfg(not(creusot))] for _ in 0..1 { #[ensures(true)] fn hidden() {} } }",
            "fn outer() { #[cfg(not(creusot))] match 0 { _ => { #[ensures(true)] fn hidden() {} } } }",
            "fn outer() { match 0 { #[cfg(not(creusot))] 0 => { #[ensures(true)] fn hidden() {} }, _ => {} } }",
            "fn outer() { #[cfg(not(creusot))] const { #[ensures(true)] fn hidden() {} }; }",
        ];
        for source in sources {
            assert!(
                inspect(source).expect("valid inactive source").is_empty(),
                "{source}"
            );
            let unresolved = source.replace("not(creusot)", r#"feature = "conditional""#);
            assert!(inspect(&unresolved).is_err(), "{unresolved}");
            let active = source.replace("not(creusot)", "creusot");
            assert_eq!(
                inspect(&active).expect("valid active source").len(),
                1,
                "{active}"
            );
        }
    }
    #[test]
    fn methods_and_boolean_cfg_are_supported() {
        let rows = inspect("struct S; impl S { #[cfg_attr(all(creusot, not(test)), ensures(true))] fn f() {} }\ntrait T { #[cfg_attr(any(test, creusot), requires(true))] fn f(); }\n").expect("valid source");
        assert_eq!(rows.len(), 2);
    }
    #[test]
    fn unresolved_conditions_and_unbound_contracts_are_unavailable() {
        assert!(inspect("#[cfg_attr(feature = \"proof\", ensures(true))] fn f() {}").is_err());
        assert!(inspect("#[cfg_attr(creusot = \"unknown\", ensures(true))] fn f() {}").is_err());
        assert!(inspect("#[ensures(true)] struct NotAFunction;").is_err());
        assert!(inspect("#[ensures(true)] fn broken(").is_err());
    }
}
