"""Application configuration layers.

Configuration is built in three passes:

    1. DEFAULT_CONFIG  -- sensible defaults for development
    2. ENVIRONMENTS    -- per-environment overrides (e.g. production)
    3. USER_OVERRIDES  -- ad-hoc tweaks from the operator

Setting a key to ``None`` in an overlay means "delete this key from
the merged result".
"""

DEFAULT_CONFIG = {
    "server": {
        "host": "localhost",
        "port": 8080,
        "workers": 4,
        "ssl": {
            "enabled": False,
            "cert_path": "/etc/ssl/cert.pem",
            "key_path": "/etc/ssl/key.pem",
        },
    },
    "database": {
        "host": "localhost",
        "port": 5432,
        "name": "myapp",
        "pool": {
            "min_size": 2,
            "max_size": 10,
        },
    },
    "logging": {
        "level": "INFO",
        "file": "/var/log/app.log",
    },
    "cache": {
        "backend": "redis",
        "ttl": 300,
    },
}

ENVIRONMENTS = {
    "production": {
        "server": {
            "host": "0.0.0.0",
            "workers": 16,
            "ssl": {
                "enabled": True,
            },
        },
        "database": {
            "host": "db.prod.internal",
            "name": "myapp_prod",
            "pool": {
                "min_size": 10,
                "max_size": 50,
            },
        },
        "logging": {
            "level": "WARNING",
        },
    },
}

# User wants to disable SSL entirely (delete the key) and bump cache TTL.
USER_OVERRIDES = {
    "server": {
        "port": 9090,
        "ssl": None,            # delete ssl section
    },
    "cache": {
        "ttl": 600,
    },
}
