// SPDX-License-Identifier: MPL-2.0
//! Minimal obligation for the published Creusot workflow canary.
//! A successful fixture run is not evidence about consumer programs.
use creusot_std::prelude::*;

#[ensures(result == value)]
pub fn identity(value: u32) -> u32 {
    value
}
