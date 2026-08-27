#!/usr/bin/env bash
# Buy the IndexBasketVault basket when at least one slot can clear minBnbToProcess
# (default 0.03 BNB *per slot*, not per vault).
#
# Setup:
#   chmod 700 script/process-basket-keeper.sh
#   cp script/keeper.env.example ~/.vault-keeper.env
#   chmod 600 ~/.vault-keeper.env   # edit RPC / VAULT / PRIVATE_KEY
#
# Cron every 5 minutes (Mac/Linux; machine must be awake):
#   crontab -e
#   */5 * * * * /bin/bash -lc 'export PATH="$HOME/.foundry/bin:$PATH"; set -a; source "$HOME/.vault-keeper.env"; set +a; "$HOME/Projects/process-basket-keeper.sh" >> "$HOME/vault-keeper.log" 2>&1'
#
# Cost: script is free. Each successful buy pays BSC gas from PRIVATE_KEY (usually cents).
# Failed/skipped runs send no transaction.
set -euo pipefail

: "${RPC:?set RPC}"
: "${VAULT:?set VAULT}"
: "${PRIVATE_KEY:?set PRIVATE_KEY}"

if ! command -v cast >/dev/null; then
  echo "cast not found; add foundry to PATH" >&2
  exit 1
fi

uint() {
  # Strip foundry decorations; keep a decimal integer.
  cast to-dec "$(cast call "$VAULT" "$1" "${@:2}" --rpc-url "$RPC")"
}

ready="$(
  python3 - "$RPC" "$VAULT" << 'PY'
import os, subprocess, sys

rpc, vault = sys.argv[1], sys.argv[2]

def call(sig, *args):
    cmd = ["cast", "call", vault, sig, *args, "--rpc-url", rpc]
    out = subprocess.check_output(cmd, text=True).strip().split()[0]
    return int(subprocess.check_output(["cast", "to-dec", out], text=True).strip())

def call_addr(sig, *args):
    cmd = ["cast", "call", vault, sig, *args, "--rpc-url", rpc]
    return subprocess.check_output(cmd, text=True).strip().split()[0]

n = call("basketLength()(uint256)")
if n == 0:
    print("0")
    sys.exit(0)
mn = call("minBnbToProcess()(uint256)")
carry = call("pendingBnbNoBasket()(uint256)")
eligible = call("totalEligibleSupply()(uint256)")
if eligible == 0:
    print("0")
    sys.exit(0)

for i in range(n):
    token = call_addr("basketTokens(uint256)(address)", str(i))
    pending = call("pendingBnbByToken(address)(uint256)", token)
    weight = call("basketWeightBps(address)(uint16)", token)
    slot = pending + carry * weight // 10000
    if slot >= mn:
        print("1")
        sys.exit(0)
print("0")
PY
)"

if [[ "$ready" != "1" ]]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) skip: no slot >= minBnbToProcess or no eligible holders"
  exit 0
fi

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) processPendingRevenue"
cast send "$VAULT" "processPendingRevenue()" --rpc-url "$RPC" --private-key "$PRIVATE_KEY"
