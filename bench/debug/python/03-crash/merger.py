"""Recursive dictionary merger for layered configuration."""

import copy


def deep_merge(base, overlay):
    """Recursively merge *overlay* into *base* and return a new dict.

    Rules
    -----
    * If both ``base[key]`` and ``overlay[key]`` are dicts, merge
      recursively.
    * If ``overlay[key]`` is ``None``, the key should be **removed**
      from the result (convention: None means "delete").
    * Otherwise, ``overlay[key]`` overwrites ``base[key]``.

    BUG: the None-means-delete convention is not implemented.  When
    ``overlay[key]`` is ``None`` the code stores ``None`` in the result
    instead of removing the key.  Downstream code that calls ``.get()``
    on nested dicts will crash with ``AttributeError: 'NoneType' object
    has no attribute 'get'``.
    """
    result = copy.deepcopy(base)

    for key, value in overlay.items():
        if (
            key in result
            and isinstance(result[key], dict)
            and isinstance(value, dict)
        ):
            result[key] = deep_merge(result[key], value)
        else:
            # BUG: should check for None and delete the key:
            #
            #     if value is None:
            #         result.pop(key, None)
            #     else:
            #         result[key] = value
            #
            result[key] = value

    return result
