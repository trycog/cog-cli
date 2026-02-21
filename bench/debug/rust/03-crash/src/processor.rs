use std::collections::HashMap;

/// Accepted internal representation produced by any parser.
#[derive(Debug)]
pub enum ParsedData {
    /// A flat key-value config (section headers become `section.key`).
    Config(HashMap<String, String>),
    /// A list of JSON-like objects (simplified to key-value maps).
    JsonRecords(Vec<HashMap<String, String>>),
    /// Tabular CSV data: header row + data rows.
    CsvTable {
        headers: Vec<String>,
        rows: Vec<Vec<String>>,
    },
}

/// Print a summary of the parsed result.
pub fn summarise(data: &ParsedData) {
    match data {
        ParsedData::Config(map) => {
            println!("Parsed config: {} values loaded", map.len());
        }
        ParsedData::JsonRecords(records) => {
            println!("Parsed JSON: {} records loaded", records.len());
        }
        ParsedData::CsvTable { headers, rows } => {
            println!(
                "Parsed CSV: {} columns, {} rows",
                headers.len(),
                rows.len()
            );
        }
    }
}
