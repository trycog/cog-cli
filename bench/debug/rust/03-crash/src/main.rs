mod processor;
mod parser;
mod json_parser;
mod csv_parser;

use processor::summarise;

/// Sample INI-style config input.
///
/// The format detector sees the leading `[` and misidentifies this as
/// a JSON array, causing a cascade: JSON parse fails, the content is
/// handed to the CSV parser, and `.unwrap()` panics on malformed rows.
///
/// The comma in the `allowed_hosts` value is critical: the CSV parser
/// sees the first non-empty line `[metadata]` (1 field, no comma), then
/// later hits `allowed_hosts = alpha, beta` which splits into 2 fields,
/// triggering the column-count mismatch panic.
const INPUT: &str = "\
[metadata]
name = test_app
version = 1.0

[network]
allowed_hosts = alpha, beta
port = 8080
timeout = 30
";

fn main() {
    let data = parser::parse(INPUT);
    summarise(&data);
}
