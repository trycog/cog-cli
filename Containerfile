FROM alpine:latest

# 1. Install all tools (Postgres, Git, Bash, Zig)
RUN apk add --no-cache \
    postgresql \
    postgresql-contrib \
    git \
    bash \
    curl \
    build-base \
    linux-headers \
    elixir \
    zig

# 2. Create swap file for memory-intensive builds
RUN dd if=/dev/zero of=/swapfile bs=1M count=2048 && \
    chmod 600 /swapfile && mkswap /swapfile

# 3. Create a wrapper script for the mounted cog binary
#    Mount the host's zig-out/bin directory to /opt/cog-bin at runtime:
#      -v /path/to/cog-cli/zig-out/bin:/opt/cog-bin
RUN printf '#!/bin/sh\nchmod +x /opt/cog-bin/cog 2>/dev/null\nexec /opt/cog-bin/cog "$@"\n' \
    > /usr/local/bin/cog && chmod +x /usr/local/bin/cog

# 4. Embed the entrypoint script
RUN cat <<'EOF' > /usr/local/bin/entrypoint.sh
#!/bin/bash
set -e

# Enable swap for memory-intensive builds
swapon /swapfile 2>/dev/null || true

# Initialize Postgres if data directory is empty
if [ ! -d "/var/lib/postgresql/data/pgdata" ]; then
    echo "First run: Initializing database..."
    mkdir -p /var/lib/postgresql/data/pgdata
    chown -R postgres:postgres /var/lib/postgresql/data
    su - postgres -c "initdb -D /var/lib/postgresql/data/pgdata"
fi

# Start Postgres in the background
echo "Starting PostgreSQL..."
su - postgres -c "pg_ctl start -D /var/lib/postgresql/data/pgdata -l /tmp/postgres.log"

# Create the default DB
su - postgres -c "psql -c 'CREATE DATABASE debug_db;'" || true

# Execute the user's command (Bash)
exec "$@"
EOF

# 5. Create cog config directory
RUN mkdir -p /root/.config/cog

# 6. Final plumbing
RUN chmod +x /usr/local/bin/entrypoint.sh
RUN mkdir -p /run/postgresql && chown -R postgres:postgres /run/postgresql
RUN git config --global --add safe.directory /src

WORKDIR /src
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/bin/bash"]
