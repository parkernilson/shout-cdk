docker_image := "claude-personal"
mcp_bridge_port := "8008"

# List available recipes
default:
    @just --list

# Run the claude-personal Docker image against this project, with the
# container able to reach the mcp-proxy bridge running on the host
# (see the `mcp-proxy` recipe below).
claude-personal:
    docker run -it --rm \
        -v "$PWD":/workspace/"$(basename "$PWD")" \
        -w /workspace/"$(basename "$PWD")" \
        -v claude-personal-config:/root/.claude \
        -v claude-personal-local:/root/.local \
        --add-host=host.docker.internal:host-gateway \
        -e MCP_BRIDGE_URL="http://host.docker.internal:{{mcp_bridge_port}}/sse" \
        {{docker_image}}

# Run mcp-proxy on the host, wrapping the sveltekit mcp server
# (stdio) and exposing it over SSE on mcp_bridge_port so the containerized
# claude-personal can reach it at http://host.docker.internal:{{mcp_bridge_port}}/sse
mcp-proxy:
    mcp-proxy --port {{mcp_bridge_port}} -- npx -y @sveltejs/mcp
