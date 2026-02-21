use crate::processor::ParsedData;

/// Parse CSV content (comma-separated values with a header row).
///
/// The first non-empty line is treated as the header.  Subsequent
/// lines are data rows.  Each field is parsed by splitting on commas
/// and trimming whitespace.
///
/// # Panics
///
/// Panics (via `.unwrap()`) if any data row has fewer fields than the
/// header — this is the crash that triggers when a config file is
/// mistakenly routed here.
pub fn parse_csv(content: &str) -> Result<ParsedData, String> {
    let lines: Vec<&str> = content
        .lines()
        .map(|l| l.trim())
        .filter(|l| !l.is_empty())
        .collect();

    if lines.is_empty() {
        return Err("Empty CSV content".into());
    }

    let headers: Vec<String> = lines[0]
        .split(',')
        .map(|h| h.trim().to_string())
        .collect();

    let num_cols = headers.len();
    let mut rows: Vec<Vec<String>> = Vec::new();

    for (line_no, &line) in lines[1..].iter().enumerate() {
        let fields: Vec<String> = line
            .split(',')
            .map(|f| f.trim().to_string())
            .collect();

        // Validate that every row has exactly the right number of columns.
        // The .unwrap() below is intentional: it will panic when a config
        // file line like "name = test_app" is parsed as CSV, because the
        // assertion result is `Err`.
        let valid = (fields.len() == num_cols)
            .then_some(())
            .ok_or_else(|| {
                format!(
                    "Row {} has {} fields, expected {} (line: {:?})",
                    line_no + 2,
                    fields.len(),
                    num_cols,
                    line
                )
            });

        // BUG TRIGGER: unwrap panics on malformed rows.
        valid.unwrap();

        rows.push(fields);
    }

    Ok(ParsedData::CsvTable { headers, rows })
}
