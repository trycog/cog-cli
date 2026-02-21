from dataset import Dataset
from correlation import CorrelationCalculator


def main():
    # Dataset with 3 variables and known correlations
    # x = [1,2,3,4,5], y = [2,4,5,4,5], z = [5,3,4,2,1]
    #
    # Correct Pearson correlations:
    #   r(x,y) =  0.775
    #   r(x,z) = -0.900
    #   r(y,z) = -0.645
    data = Dataset(
        columns=["x", "y", "z"],
        data=[
            [1, 2, 5],
            [2, 4, 3],
            [3, 5, 4],
            [4, 4, 2],
            [5, 5, 1],
        ],
    )

    calc = CorrelationCalculator()
    matrix = calc.correlation_matrix(data)

    print("Correlation matrix:")
    for row in matrix:
        print("  ".join(f"{v:6.3f}" for v in row))


if __name__ == "__main__":
    main()
