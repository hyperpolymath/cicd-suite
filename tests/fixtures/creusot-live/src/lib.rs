// SPDX-License-Identifier: MPL-2.0
use creusot_std::prelude::*;

#[ensures(result == x)]
pub fn identity(x: u32) -> u32 {
    x
}
