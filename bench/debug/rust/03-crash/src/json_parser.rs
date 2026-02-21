use std::collections::HashMap;

use crate::processor::ParsedData;

/// A minimal JSON-array-of-objects parser.
///
/// This only handles the trivial subset used in the benchmark:
///
/// ```json
/// [
///   {"key": "value", "key2": "value2"},
///   ...
/// ]
/// ```
///
/// Returns `Err` if the content is not valid simplified-JSON.
pub fn parse_json(content: &str) -> Result<ParsedData, String> {
    let trimmed = content.trim();

    if !trimmed.starts_with('[') || !trimmed.ends_with(']') {
        return Err("Not a JSON array".into());
    }

    let inner = &trimmed[1..trimmed.len() - 1];
    let mut records: Vec<HashMap<String, String>> = Vec::new();

    // Rough split on '},' to get individual objects.
    for chunk in split_objects(inner) {
        let chunk = chunk.trim().trim_matches(|c| c == '{' || c == '}');
        if chunk.is_empty() {
            continue;
        }
        let mut map = HashMap::new();
        for pair in chunk.split(',') {
            let pair = pair.trim();
            if pair.is_empty() {
                continue;
            }
            let parts: Vec<&str> = pair.splitn(2, ':').collect();
            if parts.len() != 2 {
                return Err(format!("Invalid JSON pair: {}", pair));
            }
            let key = parts[0].trim().trim_matches('"').to_string();
            let val = parts[1].trim().trim_matches('"').to_string();
            map.insert(key, val);
        }
        if !map.is_empty() {
            records.push(map);
        }
    }

    if records.is_empty() {
        return Err("JSON array contained no objects".into());
    }

    Ok(ParsedData::JsonRecords(records))
}

/// Split the inner content of a JSON array into individual object strings.
fn split_objects(inner: &str) -> Vec<String> {
    let mut objects = Vec::new();
    let mut depth = 0i32;
    let mut current = String::new();

    for ch in inner.chars() {
        match ch {
            '{' => {
                depth += 1;
                current.push(ch);
            }
            '}' => {
                depth -= 1;
                current.push(ch);
                if depth == 0 {
                    objects.push(current.clone());
                    current.clear();
                }
            }
            ',' if depth == 0 => {
                // skip commas between objects
            }
            _ => {
                current.push(ch);
            }
        }
    }

    if !current.trim().is_empty() {
        objects.push(current);
    }

    objects
}
