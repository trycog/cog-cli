class Dataset:
    """Tabular dataset with named columns."""

    def __init__(self, columns, data):
        """
        columns: list of column names
        data: list of rows (each row is a list of values)
        """
        self.columns = columns
        self.data = data
        self._validate()

    def _validate(self):
        for i, row in enumerate(self.data):
            if len(row) != len(self.columns):
                raise ValueError(
                    f"Row {i} has {len(row)} values, expected {len(self.columns)}"
                )

    def get_column(self, name):
        """Get all values for a column by name."""
        idx = self.columns.index(name)
        return [row[idx] for row in self.data]

    def num_columns(self):
        return len(self.columns)

    def num_rows(self):
        return len(self.data)
