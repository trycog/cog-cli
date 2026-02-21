class DataFrame {
  constructor(columns, rows) {
    this.columns = columns;
    this.rows = rows;
  }

  getColumn(name) {
    const idx = this.columns.indexOf(name);
    if (idx === -1) throw new Error(`Column not found: ${name}`);
    return this.rows.map(row => row[idx]);
  }

  get length() {
    return this.rows.length;
  }
}

module.exports = { DataFrame };
