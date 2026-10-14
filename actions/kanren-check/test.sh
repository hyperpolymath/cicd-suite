#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# test.sh — the miniKanren gate must fail for each thing it claims to check,
# under the exact composite shell, against a REAL relational program: a
# microKanren (Hemann & Friedman 2013) with the usual run/fresh/conde layer,
# executed by Guile. A planted wrong expectation must fail; a planted
# `conda` must be listed; a claim with no relations must be named.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
checker="$here/check.sh"
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }
command -v guile >/dev/null || { echo "guile is required (apt-get install guile-3.0)"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
OUT="$WORK/out"
FIX="$WORK/fixture"

fresh_fixture() {
    rm -rf "$FIX"; mkdir -p "$FIX/tests"
    git -C "$FIX" init -q
    git -C "$FIX" config user.email t@example.invalid
    git -C "$FIX" config user.name t
    cat > "$FIX/mk.scm" <<'SCM'
;; mk.scm — microKanren (Hemann & Friedman 2013) + the run/fresh/conde layer.
(define (var c) (vector c))
(define (var? x) (vector? x))
(define (var=? a b) (= (vector-ref a 0) (vector-ref b 0)))
(define (assp p l) (cond ((null? l) #f) ((p (caar l)) (car l)) (else (assp p (cdr l)))))
(define (walk u s)
  (let ((pr (and (var? u) (assp (lambda (v) (var=? u v)) s))))
    (if pr (walk (cdr pr) s) u)))
(define (ext-s x v s) (cons (cons x v) s))
(define mzero '())
(define (unit s/c) (cons s/c mzero))
(define (unify u v s)
  (let ((u (walk u s)) (v (walk v s)))
    (cond ((and (var? u) (var? v) (var=? u v)) s)
          ((var? u) (ext-s u v s))
          ((var? v) (ext-s v u s))
          ((and (pair? u) (pair? v))
           (let ((s (unify (car u) (car v) s))) (and s (unify (cdr u) (cdr v) s))))
          (else (and (eqv? u v) s)))))
(define (== u v)
  (lambda (s/c) (let ((s (unify u v (car s/c)))) (if s (unit (cons s (cdr s/c))) mzero))))
(define (call/fresh f)
  (lambda (s/c) (let ((c (cdr s/c))) ((f (var c)) (cons (car s/c) (+ c 1))))))
(define (mplus $1 $2)
  (cond ((null? $1) $2)
        ((procedure? $1) (lambda () (mplus $2 ($1))))
        (else (cons (car $1) (mplus (cdr $1) $2)))))
(define (bind $ g)
  (cond ((null? $) mzero)
        ((procedure? $) (lambda () (bind ($) g)))
        (else (mplus (g (car $)) (bind (cdr $) g)))))
(define (disj g1 g2) (lambda (s/c) (mplus (g1 s/c) (g2 s/c))))
(define (conj g1 g2) (lambda (s/c) (bind (g1 s/c) g2)))
(define-syntax Zzz (syntax-rules () ((_ g) (lambda (s/c) (lambda () (g s/c))))))
(define-syntax conj+ (syntax-rules () ((_ g) (Zzz g)) ((_ g0 g ...) (conj (Zzz g0) (conj+ g ...)))))
(define-syntax disj+ (syntax-rules () ((_ g) (Zzz g)) ((_ g0 g ...) (disj (Zzz g0) (disj+ g ...)))))
(define-syntax conde (syntax-rules () ((_ (g0 g ...) ...) (disj+ (conj+ g0 g ...) ...))))
(define-syntax fresh
  (syntax-rules ()
    ((_ () g0 g ...) (conj+ g0 g ...))
    ((_ (x0 x ...) g0 g ...) (call/fresh (lambda (x0) (fresh (x ...) g0 g ...))))))
(define empty-state (cons '() 0))
(define (pull $) (if (procedure? $) (pull ($)) $))
(define (take-all $) (let (($ (pull $))) (if (null? $) '() (cons (car $) (take-all (cdr $))))))
(define (take n $)
  (if (zero? n) '()
      (let (($ (pull $))) (if (null? $) '() (cons (car $) (take (- n 1) (cdr $)))))))
(define (walk* v s)
  (let ((v (walk v s)))
    (cond ((var? v) v) ((pair? v) (cons (walk* (car v) s) (walk* (cdr v) s))) (else v))))
(define (reify-name n) (string->symbol (string-append "_." (number->string n))))
(define (reify-s v s)
  (let ((v (walk v s)))
    (cond ((var? v) (cons (cons v (reify-name (length s))) s))
          ((pair? v) (reify-s (cdr v) (reify-s (car v) s)))
          (else s))))
(define (reify-1st s/c) (let ((v (walk* (var 0) (car s/c)))) (walk* v (reify-s v '()))))
(define (call/empty-state g) (g empty-state))
(define-syntax run
  (syntax-rules () ((_ n (x ...) g0 g ...) (map reify-1st (take n (call/empty-state (fresh (x ...) g0 g ...)))))))
(define-syntax run*
  (syntax-rules () ((_ (x ...) g0 g ...) (map reify-1st (take-all (call/empty-state (fresh (x ...) g0 g ...)))))))
SCM
    cat > "$FIX/appendo.scm" <<'SCM'
;; appendo.scm — the canonical relation, over mk.scm.
(load "mk.scm")
(define (appendo l s out)
  (conde
    ((== '() l) (== s out))
    ((fresh (a d res)
       (== (cons a d) l)
       (== (cons a res) out)
       (appendo d s res)))))
SCM
    cat > "$FIX/tests/appendo-test.scm" <<'SCM'
;; appendo-test.scm — run the relation forwards and backwards.
(load "../mk.scm")
(load "../appendo.scm")
(define (check name got want)
  (unless (equal? got want)
    (display name) (display ": expected ") (write want) (display ", got ") (write got) (newline)
    (exit 1)))
(check "forwards"  (run* (q) (appendo '(1 2) '(3) q)) '((1 2 3)))
(check "backwards" (run 3 (q) (fresh (x y) (appendo x y '(1 2)) (== (cons x y) q)))
       '((() 1 2) ((1) 2) ((1 2))))
(display "appendo: 2 goals hold") (newline)
SCM
    printf '= fx\n\nA relational fixture.\n' > "$FIX/README.adoc"
    git -C "$FIX" add -A && git -C "$FIX" commit -qm fixture
}
commit() { git -C "$FIX" add -A && git -C "$FIX" commit -qm change >/dev/null; }
run_gate() { ( cd "$FIX" && env "$@" bash --noprofile --norc -e -o pipefail "$checker" ) > "$OUT" 2>&1; RC=$?; }

echo "== the fixture relation really runs, forwards and backwards =="
fresh_fixture
run_gate WORKING_DIRECTORY=.
[ "$RC" -eq 0 ] && ok "gate exits 0" || { bad "gate exits $RC"; cat "$OUT"; }
grep -q 'relational Scheme files=2 (tests=1)' "$OUT" && grep -q '  engine: mk.scm' "$OUT" \
    && ok "detects 2 relational files, 1 test, and the engine" || bad "detection wrong: $(head -4 "$OUT")"
grep -q 'appendo: 2 goals hold' "$OUT" && ok "Guile executed the relational test" || bad "test did not run"
grep -q 'ok: tests/appendo-test.scm' "$OUT" && ok "the test is reported ok" || bad "test not reported"

echo "== a wrong expectation fails the gate (the relation is the oracle) =="
sed -i "s/'((1 2 3)))/'((1 2 4)))/" "$FIX/tests/appendo-test.scm"; commit
run_gate WORKING_DIRECTORY=.
[ "$RC" -eq 1 ] && ok "exits 1" || bad "exits $RC, expected 1"
grep -q 'forwards: expected ((1 2 4)), got ((1 2 3))' "$OUT" && ok "the failing goal is in the log" || bad "goal not logged"
grep -q '::error::kanren-check: relational test tests/appendo-test.scm failed' "$OUT" && ok "the test file is annotated" || bad "not annotated"
sed -i "s/'((1 2 4)))/'((1 2 3)))/" "$FIX/tests/appendo-test.scm"; commit

echo "== T2: relations with no test file =="
git -C "$FIX" rm -q tests/appendo-test.scm; commit
run_gate WORKING_DIRECTORY=.
[ "$RC" -eq 1 ] && ok "exits 1 by default" || bad "exits $RC, expected 1"
grep -q 'T2 relations without a goal-level test' "$OUT" && ok "names T2" || bad "T2 not named"
run_gate WORKING_DIRECTORY=. REQUIRE_TESTS=false
[ "$RC" -eq 0 ] && ok "a warning with REQUIRE_TESTS=false" || bad "exits $RC with REQUIRE_TESTS=false"
git -C "$FIX" checkout -q HEAD~1 -- tests/appendo-test.scm; commit

echo "== T3: an impure operator is listed, and fails when enforced =="
printf '\n(define (bad x) (conda ((== x 1)) ((== x 2))))\n' >> "$FIX/appendo.scm"; commit
run_gate WORKING_DIRECTORY=.
[ "$RC" -eq 0 ] && ok "conda is a warning by default" || bad "conda failed by default (exit $RC)"
grep -q "::warning::kanren-check: T3 impure operator 'conda' at appendo.scm:" "$OUT" && ok "conda is named with its location" || bad "conda not named: $(grep T3 "$OUT")"
run_gate WORKING_DIRECTORY=. ENFORCE_PURITY=true
[ "$RC" -eq 1 ] && ok "conda fails with ENFORCE_PURITY=true" || bad "ENFORCE_PURITY did not fail (exit $RC)"
git -C "$FIX" checkout -q HEAD~1 -- appendo.scm; commit

echo "== no interpreter is exit 2, never a pass =="
BASH_BIN="$(command -v bash)"
# A PATH with every tool the gate needs EXCEPT an interpreter (/bin is /usr/bin
# on merged-usr systems, so a plain /bin would still find guile).
NOBIN="$WORK/nobin"; mkdir -p "$NOBIN"
for t in git grep sed awk tr dirname basename head wc xargs find sort cat mktemp env; do ln -sf "$(command -v "$t")" "$NOBIN/$t"; done
( cd "$FIX" && env WORKING_DIRECTORY=. PATH="$NOBIN" "$BASH_BIN" --noprofile --norc -e -o pipefail "$checker" ) > "$OUT" 2>&1; RC=$?
[ "$RC" -eq 2 ] && ok "exits 2 without guile" || bad "exits $RC without guile, expected 2 ($(tail -1 "$OUT"))"

echo "== T1: a claim with no relations =="
git -C "$FIX" rm -q mk.scm appendo.scm tests/appendo-test.scm; commit
printf '= fx\n\nThe rule base uses miniKanren for all decisions.\n' > "$FIX/README.adoc"; commit
run_gate WORKING_DIRECTORY=.
[ "$RC" -eq 0 ] && ok "a claim is a warning by default" || bad "claim failed by default (exit $RC)"
grep -q 'T1 claim without relations: README.adoc:3' "$OUT" && ok "the claim is located" || bad "claim not located: $(cat "$OUT")"
run_gate WORKING_DIRECTORY=. ENFORCE_CLAIMS=true
[ "$RC" -eq 1 ] && ok "and fails with ENFORCE_CLAIMS=true" || bad "ENFORCE_CLAIMS did not fail (exit $RC)"
printf '= fx\n\nA miniKanren reasoner is proposed as the default; see the roadmap.\n' > "$FIX/README.adoc"; commit
run_gate WORKING_DIRECTORY=. ENFORCE_CLAIMS=true
[ "$RC" -eq 0 ] && ok "a proposal is not a claim" || bad "a proposal fired T1 (exit $RC)"
grep -q 'silent, not green-as-assurance' "$OUT" && ok "says it is silent" || bad "no silence notice"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
