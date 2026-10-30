//! Language of the messages the backend hands to the interface.
//!
//! The interface owns the choice and reports it through `set_language`. Errors
//! are rare, so both versions are simply formatted and one is dropped.

use std::sync::atomic::{AtomicBool, Ordering};

static ENGLISH: AtomicBool = AtomicBool::new(false);

pub fn set_language(lang: &str) {
    ENGLISH.store(lang != "ru", Ordering::Relaxed);
}

pub fn tr(ru: impl Into<String>, en: impl Into<String>) -> String {
    if ENGLISH.load(Ordering::Relaxed) {
        en.into()
    } else {
        ru.into()
    }
}
