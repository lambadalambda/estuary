//! dcvm: headless DeltaChat viewmodel. Placeholder while dependency graph pre-warms.

pub fn core_version() -> String {
    deltachat::get_version_str().to_string()
}
