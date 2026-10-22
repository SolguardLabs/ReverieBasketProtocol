#!/usr/bin/env bash
set -euo pipefail

bun run build
bun run typecheck
bun run test
