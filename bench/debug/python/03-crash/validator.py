"""Configuration validator -- checks invariants and counts settings."""


def count_leaf_settings(config, prefix=""):
    """Recursively count all leaf (non-dict) values in *config*."""
    count = 0
    for key, value in config.items():
        full_key = f"{prefix}.{key}" if prefix else key
        if isinstance(value, dict):
            count += count_leaf_settings(value, full_key)
        else:
            count += 1
    return count


def validate_config(config):
    """Validate the merged configuration.

    Checks a handful of business rules and returns the total number of
    leaf settings on success.

    CRASH PATH
    ----------
    After the buggy merge, ``config["server"]["ssl"]`` is ``None``
    (the merger stored it literally instead of deleting the key).
    The line::

        ssl_config.get("enabled")

    raises ``AttributeError: 'NoneType' object has no attribute 'get'``
    because ``ssl_config`` is ``None``, not a dict.
    """
    errors = []

    # -- Validate server section ------------------------------------------
    server = config.get("server", {})

    # Retrieve SSL sub-section; default to empty dict if absent.
    ssl_config = server.get("ssl", {})

    # When the merger bug is present, ssl_config is None (not a dict).
    # The next call crashes: NoneType has no attribute 'get'.
    if ssl_config.get("enabled"):
        cert = ssl_config.get("cert_path", "")
        key = ssl_config.get("key_path", "")
        if not cert or not key:
            errors.append("SSL enabled but cert_path / key_path missing")

    # -- Validate database section ----------------------------------------
    db = config.get("database", {})
    pool = db.get("pool", {})
    if pool.get("min_size", 0) > pool.get("max_size", 0):
        errors.append("pool min_size exceeds max_size")

    # -- Count settings ---------------------------------------------------
    total = count_leaf_settings(config)

    if errors:
        raise ValueError(f"Config validation failed: {errors}")

    return total
