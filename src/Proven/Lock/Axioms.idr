-- SPDX-License-Identifier: MPL-2.0
||| TRUSTED BASE of the proven lock kernel: the only axioms it uses.
|||
||| Both are facts about primitive String equality. The standard library's
||| `DecEq String` rests on the same assumption through an unnamed
||| `believe_me`; here they are named and isolated, so the whole trusted base
||| is this file. tests/proven-lock-proofs.sh enforces that this module holds
||| exactly two `believe_me` and that no other kernel module holds any escape
||| hatch.
module Proven.Lock.Axioms

import Data.So

%default total

||| Primitive equality is sound: `x == y` evaluating to True means x = y.
public export
stringEqSound : (x, y : String) -> So (x == y) -> x = y
stringEqSound x _ _ = believe_me (the (x = x) Refl)

||| Primitive equality is reflexive.
public export
stringEqRefl : (x : String) -> So (x == x)
stringEqRefl _ = believe_me Oh
