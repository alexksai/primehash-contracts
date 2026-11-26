#!/usr/bin/env bash
# PrimeHash mainnet launch. Deploys everything in one run, verifies the sources and writes the website config.
#
#   cd contracts
#   cp .env.mainnet.example .env.mainnet   # fill TREASURY, LAUNCH_ETH, optional ETHERSCAN_API_KEY
#   cast wallet import primehash-deployer --interactive   # the mainnet deployer key, never pasted anywhere else
#   ./script/deploy-mainnet.sh            # dry run on a mainnet fork first, then asks before broadcasting
#
# Safety: refuses to run on the wrong chain, with too little ETH, or above MAX_GWEI; simulates on a local fork
# first; needs you to type the confirmation phrase before anything is sent.
set -euo pipefail
cd "$(dirname "$0")/.."
F=~/.foundry/bin
[[ -f .env.mainnet ]] || { echo "Missing contracts/.env.mainnet (copy .env.mainnet.example)"; exit 1; }
set -a; . ./.env.mainnet; set +a

: "${MAINNET_RPC_URL:?set MAINNET_RPC_URL}"
: "${TREASURY:?set TREASURY (a Safe multisig is recommended)}"
: "${LAUNCH_ETH:?set LAUNCH_ETH in wei}"
ACCOUNT=${DEPLOYER_ACCOUNT:-primehash-deployer}
# KEYSTORE=/path/to/keystore-file overrides the named account (password from the prompt or ETH_PASSWORD)
if [[ -n "${KEYSTORE:-}" ]]; then SIGNER=(--keystore "$KEYSTORE"); else SIGNER=(--account "$ACCOUNT"); fi
MAX_GWEI=${MAX_GWEI:-3}
DEPLOY_GAS=7600000 # measured on a mainnet fork: 7,548,153

CHAIN=$($F/cast chain-id --rpc-url "$MAINNET_RPC_URL")
[[ "$CHAIN" == "1" ]] || { echo "RPC is chain $CHAIN, not Ethereum mainnet"; exit 1; }
DEPLOYER=$($F/cast wallet address "${SIGNER[@]}")
BAL=$($F/cast balance "$DEPLOYER" --rpc-url "$MAINNET_RPC_URL")
GAS=$($F/cast gas-price --rpc-url "$MAINNET_RPC_URL")
NEED=$(python3 -c "print(int($DEPLOY_GAS*$GAS*1.25) + $LAUNCH_ETH)")
GWEI=$(python3 -c "print(f'{$GAS/1e9:.3f}')")
eth() { python3 -c "print(f'{$1/1e18:.5f}')"; }

echo "Deployer      $DEPLOYER"
echo "Treasury      $TREASURY"
echo "Balance       $(eth "$BAL") ETH"
echo "Gas price     $GWEI gwei (limit $MAX_GWEI)"
echo "Launch LP     $(eth "$LAUNCH_ETH") ETH + 21,000 PRIME  ->  $(python3 -c "print(f'{21000e18/$LAUNCH_ETH:,.0f}')") PRIME per ETH"
echo "Needed        ~$(eth "$NEED") ETH (gas x1.25 + launch ETH)"
python3 -c "import sys; sys.exit(0 if $GAS/1e9 <= $MAX_GWEI else 1)" || { echo "Gas above $MAX_GWEI gwei: wait for a cheaper moment (or raise MAX_GWEI)."; exit 1; }
python3 -c "import sys; sys.exit(0 if $BAL >= $NEED else 1)" || { echo "Not enough ETH on the deployer."; exit 1; }

echo; echo "== Dry run on a local mainnet fork"
PORT=8599
$F/anvil --fork-url "$MAINNET_RPC_URL" --port $PORT --silent &
ANVIL=$!
trap 'kill $ANVIL 2>/dev/null || true' EXIT
until $F/cast chain-id --rpc-url http://127.0.0.1:$PORT >/dev/null 2>&1; do sleep 0.5; done
$F/cast rpc anvil_impersonateAccount "$DEPLOYER" --rpc-url http://127.0.0.1:$PORT >/dev/null
env -u ETH_PASSWORD -u ETH_KEYSTORE $F/forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:$PORT --sender "$DEPLOYER" --unlocked --broadcast --slow >/dev/null
echo "Dry run OK."
kill $ANVIL 2>/dev/null || true
trap - EXIT

echo
read -r -p 'Type "DEPLOY MAINNET" to broadcast for real: ' ok
[[ "$ok" == "DEPLOY MAINNET" ]] || { echo "Aborted, nothing sent."; exit 1; }

$F/forge script script/Deploy.s.sol --rpc-url "$MAINNET_RPC_URL" "${SIGNER[@]}" --sender "$DEPLOYER" --broadcast --slow

RUN=broadcast/Deploy.s.sol/1/run-latest.json
read -r RESERVE ENGINE TOKEN HOOK ZAP BLOCK < <(python3 - "$RUN" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
a = {t["contractName"]: t["contractAddress"] for t in d["transactions"] if t["transactionType"] in ("CREATE", "CREATE2")}
print(a["GenesisReserve"], a["MiningEngine"], a["PrimeToken"], a["PrimeHashHook"], a["MiningZap"], int(d["receipts"][0]["blockNumber"], 16))
PY
)

echo; echo "== Verifying sources"
for pair in "$RESERVE src/GenesisReserve.sol:GenesisReserve" "$ENGINE src/MiningEngine.sol:MiningEngine" "$TOKEN src/PrimeToken.sol:PrimeToken" "$HOOK src/PrimeHashHook.sol:PrimeHashHook" "$ZAP src/MiningZap.sol:MiningZap"; do
  set -- $pair
  $F/forge verify-contract "$1" "$2" --chain mainnet --verifier sourcify --guess-constructor-args --rpc-url "$MAINNET_RPC_URL" --watch || true
  if [[ -n "${ETHERSCAN_API_KEY:-}" ]]; then
    $F/forge verify-contract "$1" "$2" --chain mainnet --etherscan-api-key "$ETHERSCAN_API_KEY" --guess-constructor-args --rpc-url "$MAINNET_RPC_URL" --watch || true
  fi
done

cat > ../web/.env.production.local <<ENV
# PrimeHash on Ethereum mainnet (written by contracts/script/deploy-mainnet.sh). Used by \`npm run build\`.
NEXT_PUBLIC_CHAIN_ID=1
NEXT_PUBLIC_RPC_URL=${PUBLIC_RPC_URLS:-https://ethereum-rpc.publicnode.com,https://eth.drpc.org,https://1rpc.io/eth}
NEXT_PUBLIC_ENGINE=$ENGINE
NEXT_PUBLIC_HOOK=$HOOK
NEXT_PUBLIC_RESERVE=$RESERVE
NEXT_PUBLIC_TOKEN=$TOKEN
NEXT_PUBLIC_ZAP=$ZAP
NEXT_PUBLIC_DEPLOY_BLOCK=$BLOCK
ENV

echo
echo "PrimeHash is live on Ethereum mainnet."
echo "  PRIME           $TOKEN"
echo "  MiningEngine    $ENGINE"
echo "  PrimeHashHook   $HOOK"
echo "  MiningZap       $ZAP"
echo "  GenesisReserve  $RESERVE"
echo "Website config: web/.env.production.local  ->  cd ../web && npm run build  (static site in web/out/)"
