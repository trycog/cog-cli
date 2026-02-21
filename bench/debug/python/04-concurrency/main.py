from pipeline import Pipeline


def main():
    pipeline = Pipeline(num_items=200)
    results, elapsed = pipeline.run(timeout=10)

    if results is not None:
        print(f"Processed {len(results)} items")
    # If timeout, pipeline.run already printed the timeout message


if __name__ == "__main__":
    main()
