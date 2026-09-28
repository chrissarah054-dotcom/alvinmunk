#!/usr/bin/env bash
# Deploy the 5 Soroban contracts to Stellar MAINNET with comprehensive safety gates.
# 
# MAINNET IS IRREVERSIBLE. This script enforces:
#   1. Network passphrase is "Public Global Stellar Network ; September 2015" (NOT testnet)
#   2. USDC SAC is Circle's canonical mainnet address
#   3. Operator must type "mainnet" at a confirmation prompt
#   4. Dry-run support (DRY_RUN=1) prints all commands without network writes
#   5. Automatic logging of contract IDs, WASM hashes, deployer key, and commit SHA
#
# Prerequisites:
#   - stellar CLI installed (brew install stellar-cli or cargo install stellar-cli)
#   - Admin and Attester keys generated and funded on mainnet:
#     stellar keys generate admin --network mainnet
#     stellar keys generate attester --network mainnet
#   - Mainnet network configured:
#     stellar network add mainnet \
#       --rpc-url https://mainnet.sorobanrpc.com \
#       --network-passphrase "Public Global Stellar Network ; September 2015"
#
# Usage:
#   ADMIN=admin ATTESTER=attester USDC_SAC=<circle_sac_id> \
#     DAILY_CAP=500000000 ./scripts/deploy-mainnet.sh
#
# Dry-run (prints plan, submits no transactions):
#   DRY_RUN=1 ADMIN=admin ATTESTER=attester USDC_SAC=<circle_sac_id> \
#     DAILY_CAP=500000000 ./scripts/deploy-mainnet.sh
#
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# Configuration & Validation
# ─────────────────────────────────────────────────────────────

ADMIN="${ADMIN:-}"
ATTESTER="${ATTESTER:-}"
NETWORK="mainnet"
DRY_RUN="${DRY_RUN:-0}"

# Circle's canonical mainnet USDC SAC address
CANONICAL_USDC="CAKSAOXC5CZ4HWL7G7F6BBXW7Z54A6Z4UFHFVOWMPCBAGBNNJF7NKH42"
USDC_SAC="${USDC_SAC:-}"

# Required for set_require_funding(true) circuit breaker (USDC mint budget in stroops)
DAILY_CAP="${DAILY_CAP:-}"

# Colors for output (disabled in CI, enabled in terminal)
if [ -t 1 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  NC='\033[0m' # No Color
else
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  NC=''
fi

# ─────────────────────────────────────────────────────────────
# Utility Functions
# ─────────────────────────────────────────────────────────────

log_error() {
  echo -e "${RED}✗ ERROR: $*${NC}" >&2
}

log_success() {
  echo -e "${GREEN}✅ $*${NC}"
}

log_info() {
  echo -e "${BLUE}==> $*${NC}"
}

log_warn() {
  echo -e "${YELLOW}⚠ $*${NC}"
}

die() {
  log_error "$@"
  exit 1
}

# Retry wrapper for idempotent post-deploy calls (survives transient TxBadSeq races).
# $1 = contract id
# $2+ = command args (everything after the id)
invoke_with_retry() {
  local contract_id="$1"
  shift
  local max_retries=5
  local attempt=1

  if [ "$DRY_RUN" = "1" ]; then
    echo "  stellar contract invoke --id $contract_id --source $ADMIN --network $NETWORK -- $@"
    return 0
  fi

  while [ $attempt -le $max_retries ]; do
    if stellar contract invoke --id "$contract_id" --source "$ADMIN" --network "$NETWORK" -- "$@" >/dev/null 2>&1; then
      return 0
    fi
    if [ $attempt -lt $max_retries ]; then
      log_warn "Invoke attempt $attempt/$max_retries failed for $contract_id. Retrying..."
      attempt=$((attempt + 1))
      sleep 1
    else
      log_error "Invoke failed after $max_retries retries: stellar contract invoke --id $contract_id --source $ADMIN --network $NETWORK -- $@"
      return 1
    fi
  done
}

deploy_contract() {
  local wasm_file="$1"
  local contract_name="$2"

  if [ "$DRY_RUN" = "1" ]; then
    echo "  stellar contract deploy --wasm $WASM_DIR/$wasm_file --source $ADMIN --network $NETWORK"
    # In dry-run, emit a fake ID (uppercase hex)
    echo "CABC123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456"
    return 0
  fi

  local id
  id=$(stellar contract deploy --wasm "$WASM_DIR/$wasm_file" --source "$ADMIN" --network "$NETWORK" 2>&1) || die "Failed to deploy $contract_name"
  echo "$id"
}

# ─────────────────────────────────────────────────────────────
# Pre-flight Checks
# ─────────────────────────────────────────────────────────────

log_info "Pre-flight validation"

# Check required environment variables
[ -z "$ADMIN" ] && die "ADMIN not set. Usage: ADMIN=admin ATTESTER=attester ./scripts/deploy-mainnet.sh"
[ -z "$ATTESTER" ] && die "ATTESTER not set. Usage: ADMIN=admin ATTESTER=attester ./scripts/deploy-mainnet.sh"
[ -z "$USDC_SAC" ] && die "USDC_SAC not set. Use Circle's mainnet USDC: USDC_SAC=$CANONICAL_USDC"
[ -z "$DAILY_CAP" ] && die "DAILY_CAP not set (required for mainnet). Example: DAILY_CAP=500000000"

# Verify stellar CLI is installed
command -v stellar >/dev/null 2>&1 || die "stellar CLI not installed. Install: brew install stellar-cli"

# Verify keys exist
stellar keys address "$ADMIN" >/dev/null 2>&1 || die "Key '$ADMIN' not found. Generate with: stellar keys generate $ADMIN --network mainnet"
stellar keys address "$ATTESTER" >/dev/null 2>&1 || die "Key '$ATTESTER' not found. Generate with: stellar keys generate $ATTESTER --network mainnet"

ADMIN_ADDR=$(stellar keys address "$ADMIN")
ATTESTER_ADDR=$(stellar keys address "$ATTESTER")

log_info "Admin:    $ADMIN_ADDR"
log_info "Attester: $ATTESTER_ADDR"

# ─────────────────────────────────────────────────────────────
# Network & USDC Validation (THE GATES)
# ─────────────────────────────────────────────────────────────

if [ "$DRY_RUN" != "1" ]; then
  log_info "Verifying network passphrase (Gate 1 of 3)"
  
  # Fetch the network config
  local passphrase
  passphrase=$(stellar network list --format json | jq -r ".[] | select(.name==\"$NETWORK\") | .network_passphrase" 2>/dev/null) || \
    die "Cannot read network config. Ensure mainnet is configured: stellar network add mainnet --rpc-url ... --network-passphrase \"Public Global Stellar Network ; September 2015\""
  
  if [ "$passphrase" != "Public Global Stellar Network ; September 2015" ]; then
    die "TESTNET DETECTED: Network passphrase is '$passphrase', not 'Public Global Stellar Network ; September 2015'. Are you pointing to testnet by mistake?"
  fi
  log_success "Network passphrase verified: mainnet"

  log_info "Verifying USDC SAC address (Gate 2 of 3)"
  
  # Derive the USDC SAC from the canonical Circle asset
  local derived_sac
  derived_sac=$(stellar contract id asset --network "$NETWORK" --asset "USDC:$CANONICAL_USDC" 2>/dev/null) || \
    die "Cannot derive USDC SAC. Check network connectivity and Circle issuer address."
  
  if [ "$USDC_SAC" != "$derived_sac" ]; then
    log_error "USDC SAC mismatch!"
    log_error "  Expected (Circle canonical): $derived_sac"
    log_error "  Got:                         $USDC_SAC"
    die "Aborting. Do not use a custom USDC. Use: USDC_SAC=$derived_sac"
  fi
  log_success "USDC SAC verified: $USDC_SAC (Circle mainnet)"
fi

# ─────────────────────────────────────────────────────────────
# Operator Confirmation (Gate 3 of 3)
# ─────────────────────────────────────────────────────────────

if [ "$DRY_RUN" != "1" ]; then
  log_warn "⚠️  MAINNET DEPLOYMENT CONFIRMATION (Gate 3 of 3)"
  echo ""
  echo "This will deploy 5 Soroban contracts to MAINNET with real value at stake."
  echo "Mainnet is NOT reversible. Once deployed, these contracts cannot be undone."
  echo ""
  echo "Verify these settings:"
  echo "  Network:              mainnet"
  echo "  Admin key:            $ADMIN ($ADMIN_ADDR)"
  echo "  Attester key:         $ATTESTER ($ATTESTER_ADDR)"
  echo "  USDC SAC:             $USDC_SAC"
  echo "  Daily cap (stroops):  $DAILY_CAP"
  echo ""
  read -p "Type 'mainnet' to confirm deployment: " confirm
  [ "$confirm" = "mainnet" ] || die "Deployment aborted."
  log_success "Deployment confirmed by operator."
  echo ""
fi

# ─────────────────────────────────────────────────────────────
# Build & Deploy
# ─────────────────────────────────────────────────────────────

log_info "Building contracts"
if [ "$DRY_RUN" = "1" ]; then
  echo "  cd $(dirname "$0")/../contracts && stellar contract build"
else
  ( cd "$(dirname "$0")/../contracts" && stellar contract build ) || die "Build failed"
fi

WASM_DIR="$(dirname "$0")/../contracts/target/wasm32v1-none/release"

# Function to get WASM hash for logging
get_wasm_hash() {
  local wasm_file="$1"
  if [ -f "$WASM_DIR/$wasm_file" ]; then
    sha256sum "$WASM_DIR/$wasm_file" | awk '{print $1}'
  else
    echo "HASH_NOT_FOUND"
  fi
}

log_info "Deploying contracts to mainnet"
REP_ID=$(deploy_contract alvinmunk_reputation.wasm "reputation")
QUEST_ID=$(deploy_contract alvinmunk_quest_registry.wasm "quest_registry")
REWARDS_ID=$(deploy_contract alvinmunk_rewards.wasm "rewards")
REGISTRY_ID=$(deploy_contract alvinmunk_registry.wasm "registry")
GATE_ID=$(deploy_contract alvinmunk_gate.wasm "gate")

if [ "$DRY_RUN" != "1" ]; then
  log_success "Reputation:    $REP_ID"
  log_success "Quest Registry: $QUEST_ID"
  log_success "Rewards:       $REWARDS_ID"
  log_success "Registry:      $REGISTRY_ID"
  log_success "Gate:          $GATE_ID"
else
  echo "Reputation:    $REP_ID"
  echo "Quest Registry: $QUEST_ID"
  echo "Rewards:       $REWARDS_ID"
  echo "Registry:      $REGISTRY_ID"
  echo "Gate:          $GATE_ID"
fi

# ─────────────────────────────────────────────────────────────
# Initialize & Wire
# ─────────────────────────────────────────────────────────────

log_info "Initializing contracts"
invoke_with_retry "$REP_ID" init --admin "$ADMIN_ADDR" || die "Failed to init reputation"
invoke_with_retry "$QUEST_ID" init --admin "$ADMIN_ADDR" --reputation "$REP_ID" || die "Failed to init quest_registry"
invoke_with_retry "$REWARDS_ID" init --admin "$ADMIN_ADDR" --usdc "$USDC_SAC" --reputation "$REP_ID" || die "Failed to init rewards"
invoke_with_retry "$REGISTRY_ID" init --admin "$ADMIN_ADDR" || die "Failed to init registry"
invoke_with_retry "$GATE_ID" init --admin "$ADMIN_ADDR" --reputation "$REP_ID" || die "Failed to init gate"

if [ "$DRY_RUN" != "1" ]; then
  log_success "Contracts initialized"
fi

log_info "Wiring attesters"
invoke_with_retry "$REP_ID" add_attester --attester "$QUEST_ID" || die "Failed to add quest_registry as attester"
invoke_with_retry "$REP_ID" add_attester --attester "$ATTESTER_ADDR" || die "Failed to add attester"
invoke_with_retry "$QUEST_ID" add_attester --attester "$ATTESTER_ADDR" || die "Failed to add attester to quest_registry"

if [ "$DRY_RUN" != "1" ]; then
  log_success "Attesters configured"
fi

# ─────────────────────────────────────────────────────────────
# Mainnet-specific Configuration
# ─────────────────────────────────────────────────────────────

log_info "Setting mainnet safety gates"

# Enable proof-of-funding check (real money, real verification)
invoke_with_retry "$REWARDS_ID" set_require_funding --require true || die "Failed to set_require_funding"

# Set conservative daily cap (treasury circuit breaker)
invoke_with_retry "$REWARDS_ID" set_daily_cap --cap "$DAILY_CAP" || die "Failed to set_daily_cap"

if [ "$DRY_RUN" != "1" ]; then
  log_success "Mainnet gates enabled (proof-of-funding ON, daily cap set)"
fi

# ─────────────────────────────────────────────────────────────
# Logging
# ─────────────────────────────────────────────────────────────

log_info "Recording deployment metadata"

# Get metadata for logging
GIT_SHA=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
DEPLOYER_FINGERPRINT="$ADMIN_ADDR"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Get WASM hashes
REP_HASH=$(get_wasm_hash alvinmunk_reputation.wasm)
QUEST_HASH=$(get_wasm_hash alvinmunk_quest_registry.wasm)
REWARDS_HASH=$(get_wasm_hash alvinmunk_rewards.wasm)
REGISTRY_HASH=$(get_wasm_hash alvinmunk_registry.wasm)
GATE_HASH=$(get_wasm_hash alvinmunk_gate.wasm)

# Create deployment-log.md if it doesn't exist
DEPLOY_LOG="$(dirname "$0")/../deployment-log.md"
if [ ! -f "$DEPLOY_LOG" ]; then
  cat > "$DEPLOY_LOG" <<'HEADER'
# Deployment Log

Record of all production deployments: contract IDs, WASM hashes, deployer public keys, and commit SHAs.

## Mainnet Deployments

HEADER
fi

# Append deployment entry
cat >> "$DEPLOY_LOG" <<ENTRY

### Deployment $(date +%Y-%m-%d\ %H:%M:%SZ)

**Network:** mainnet  
**Timestamp:** $TIMESTAMP  
**Deployer:** $DEPLOYER_FINGERPRINT  
**Git SHA:** $GIT_SHA  
**Daily Cap:** $DAILY_CAP stroops

#### Contract IDs

| Contract | Address |
| --- | --- |
| Reputation | \`$REP_ID\` |
| Quest Registry | \`$QUEST_ID\` |
| Rewards | \`$REWARDS_ID\` |
| Registry | \`$REGISTRY_ID\` |
| Gate | \`$GATE_ID\` |

#### WASM Hashes (SHA256)

| Contract | Hash |
| --- | --- |
| Reputation | \`$REP_HASH\` |
| Quest Registry | \`$QUEST_HASH\` |
| Rewards | \`$REWARDS_HASH\` |
| Registry | \`$REGISTRY_HASH\` |
| Gate | \`$GATE_HASH\` |

#### Verification

View on Stellar Expert: https://stellar.expert/explorer/public/

- Reputation: https://stellar.expert/explorer/public/contract/$REP_ID
- Quest Registry: https://stellar.expert/explorer/public/contract/$QUEST_ID
- Rewards: https://stellar.expert/explorer/public/contract/$REWARDS_ID
- Registry: https://stellar.expert/explorer/public/contract/$REGISTRY_ID
- Gate: https://stellar.expert/explorer/public/contract/$GATE_ID

ENTRY

log_success "Deployment logged to $DEPLOY_LOG"

# ─────────────────────────────────────────────────────────────
# Output Summary
# ─────────────────────────────────────────────────────────────

if [ "$DRY_RUN" = "1" ]; then
  log_info "DRY-RUN COMPLETE (no network writes)"
  echo ""
  echo "This is the plan that would be executed:"
  echo "  • Build contracts"
  echo "  • Deploy 5 WASM files to mainnet"
  echo "  • Initialize all contracts"
  echo "  • Wire cross-contract calls and attesters"
  echo "  • Enable proof-of-funding check"
  echo "  • Set daily cap to $DAILY_CAP stroops"
  echo "  • Log deployment metadata"
  echo ""
else
  echo ""
  log_success "✨ Mainnet deployment complete!"
  echo ""
  echo "Next steps:"
  echo "  1. Verify contract IDs on stellar.expert (links in $DEPLOY_LOG)"
  echo "  2. Run smoke test: e2e-mainnet.mjs with a throwaway funded account"
  echo "  3. Update apps/web/.env.local with mainnet contract IDs (see below)"
  echo "  4. Deploy web app to production via Vercel"
  echo ""
fi

cat <<EOF

📋 Contract IDs (for apps/web/.env.local or Vercel):

NEXT_PUBLIC_STELLAR_NETWORK=mainnet
NEXT_PUBLIC_RPC_URL=https://mainnet.sorobanrpc.com
NEXT_PUBLIC_NETWORK_PASSPHRASE=Public Global Stellar Network ; September 2015
NEXT_PUBLIC_HORIZON_URL=https://horizon.stellar.org
NEXT_PUBLIC_REPUTATION_CONTRACT_ID=$REP_ID
NEXT_PUBLIC_QUEST_REGISTRY_CONTRACT_ID=$QUEST_ID
NEXT_PUBLIC_REWARDS_CONTRACT_ID=$REWARDS_ID
NEXT_PUBLIC_REGISTRY_CONTRACT_ID=$REGISTRY_ID
NEXT_PUBLIC_GATE_CONTRACT_ID=$GATE_ID
NEXT_PUBLIC_USDC_SAC_ID=$USDC_SAC

EOF

if [ "$DRY_RUN" = "1" ]; then
  echo "ℹ️  To execute this deployment, run:"
  echo "   ADMIN=admin ATTESTER=attester USDC_SAC=$USDC_SAC DAILY_CAP=$DAILY_CAP ./scripts/deploy-mainnet.sh"
fi
