"""Configuration loader -- assembles the final config from all layers."""

import copy
from config import DEFAULT_CONFIG, ENVIRONMENTS, USER_OVERRIDES
from merger import deep_merge


def load_config(environment="production"):
    """Build the final configuration dictionary.

    Layers are applied in order:

        defaults  ->  environment overlay  ->  user overrides
    """
    config = copy.deepcopy(DEFAULT_CONFIG)

    # Apply environment-specific settings
    if environment in ENVIRONMENTS:
        config = deep_merge(config, ENVIRONMENTS[environment])

    # Apply operator / user overrides
    config = deep_merge(config, USER_OVERRIDES)

    return config
