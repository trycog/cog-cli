from stats import mean, std_dev


class CorrelationCalculator:
    """Computes Pearson correlation matrix."""

    def __init__(self):
        self.sum_products = 0.0
        self.sum_sq_diff_x = 0.0  # BUG: These accumulators are instance variables
        self.sum_sq_diff_y = 0.0  # that don't get reset between column pairs

    def pearson(self, x_values, y_values):
        """Calculate Pearson correlation coefficient between two variables.

        Uses manual accumulation of sum of squared differences and
        cross-products to compute the correlation.
        """
        n = len(x_values)
        x_mean = mean(x_values)
        y_mean = mean(y_values)

        self.sum_products = 0.0  # This one IS reset correctly
        # BUG: sum_sq_diff_x and sum_sq_diff_y are NOT reset here.
        # They accumulate values from previous column pair calculations,
        # inflating the denominator and producing incorrect correlation
        # values for all pairs after the first one.
        # The fix is to add:
        #   self.sum_sq_diff_x = 0.0
        #   self.sum_sq_diff_y = 0.0

        for i in range(n):
            dx = x_values[i] - x_mean
            dy = y_values[i] - y_mean
            self.sum_products += dx * dy
            self.sum_sq_diff_x += dx * dx
            self.sum_sq_diff_y += dy * dy

        denominator = (self.sum_sq_diff_x * self.sum_sq_diff_y) ** 0.5
        if denominator == 0:
            return 0.0

        return self.sum_products / denominator

    def correlation_matrix(self, dataset):
        """Compute full correlation matrix for a dataset."""
        n_cols = dataset.num_columns()
        matrix = [[0.0] * n_cols for _ in range(n_cols)]

        columns = [dataset.get_column(name) for name in dataset.columns]

        for i in range(n_cols):
            for j in range(n_cols):
                if i == j:
                    matrix[i][j] = 1.000
                elif j > i:
                    r = self.pearson(columns[i], columns[j])
                    matrix[i][j] = r
                    matrix[j][i] = r

        return matrix
