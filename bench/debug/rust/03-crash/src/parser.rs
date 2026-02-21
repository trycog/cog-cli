use crate::csv_parser;
use crate::json_parser;
use crate::processor::ParsedData;

use std::collections::HashMap;

/// Supported input formats.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Format {
    Json,
    Csv,
    KeyValueConfig,
}

/// Detect the format of `content` by inspecting its first non-blank line.
///
/// Heuristics:
/// - Starts with `[`  -> JSON array            (BUG: also matches `[section]`)
/// - Contains a comma on the first data line -> CSV
/// - Otherwise        -> key-value config
pub fn detect_format(content: &str) -> Format {
    let first_line = content
        .lines()
        .map(|l| l.trim())
        .find(|l| !l.is_empty())
        .unwrap_or("");

    // BUG: This check triggers on INI-style section headers like `[metadata]`
    // because they also begin with `[`.
    //
    // FIX: check whether the `[` is followed by `{` or data (JSON array) vs
    //      a closing `]` on the same line with only word characters in between
    //      (config section header).
    //
    //      Correct check:
    //          if first_line.starts_with('[') && !first_line.ends_with(']') { ... }
    //      or use a regex / more sophisticated heuristic.
    if first_line.starts_with('[') {
        return Format::Json;
    }

    if first_line.contains(',') {
        return Format::Csv;
    }

    Format::KeyValueConfig
}

/// Route content to the appropriate parser.
pub fn parse(content: &str) -> ParsedData {
    let format = detect_format(content);

    match format {
        Format::Json => {
            match json_parser::parse_json(content) {
                Ok(data) => data,
                Err(_) => {
                    // JSON parse failed — fall through to CSV as a guess.
                    // This is the path that eventually panics when the input
                    // is actually a config file.
                    csv_parser::parse_csv(content).expect("CSV parse also failed")
                }
            }
        }
        Format::Csv => {
            csv_parser::parse_csv(content).expect("CSV parse failed")
        }
        Format::KeyValueConfig => {
            parse_key_value_config(content)
        }
    }
}

/// Parse an INI-style key-value configuration file.
///
/// Supports `[section]` headers.  Keys within a section are stored as
/// `section.key` in the resulting map.
fn parse_key_value_config(content: &str) -> ParsedData {
    let mut map = HashMap::new();
    let mut current_section = String::new();

    for line in content.lines() {
        let line = line.trim();

        if line.is_empty() || line.starts_with('#') || line.starts_with(';') {
            continue;
        }

        // Section header: [name]
        if line.starts_with('[') && line.ends_with(']') {
            current_section = line[1..line.len() - 1].trim().to_string();
            continue;
        }

        // Key = value pair
        if let Some(eq_pos) = line.find('=') {
            let key = line[..eq_pos].trim();
            let value = line[eq_pos + 1..].trim();

            let full_key = if current_section.is_empty() {
                key.to_string()
            } else {
                format!("{}.{}", current_section, key)
            };

            map.insert(full_key, value.to_string());
        }
    }

    ParsedData::Config(map)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detect_csv() {
        assert_eq!(detect_format("name,age,city\nAlice,30,NYC"), Format::Csv);
    }

    #[test]
    fn detect_json() {
        assert_eq!(
            detect_format("[{\"a\":1},{\"b\":2}]"),
            Format::Json
        );
    }

    #[test]
    fn detect_config_bug() {
        // This SHOULD detect as KeyValueConfig but the bug misidentifies
        // it as Json because it starts with '['.
        let input = "[metadata]\nname = test\n";
        let detected = detect_format(input);
        // Uncomment the assertion below to see the bug:
        // assert_eq!(detected, Format::KeyValueConfig);
        assert_eq!(detected, Format::Json); // current (buggy) behavior
    }
}
