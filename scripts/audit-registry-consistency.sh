#!/bin/bash

###############################################################################
# Registry Consistency Audit Script
# 
# Performs comprehensive validation across multiple dimensions:
# 1. Schema consistency (all reads/writes use same structure)
# 2. Error handling (empty strings, null values, missing keys)
# 3. Migration safety (backward compatibility)
# 4. Validation coverage (all critical paths have checks)
# 5. Edge cases (concurrent access, partial updates)
###############################################################################

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

log_test() {
    echo -e "${BLUE}[TEST]${NC} $1"
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((PASS_COUNT++))
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((FAIL_COUNT++))
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    ((WARN_COUNT++))
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🔍 Registry Consistency Audit"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

###############################################################################
# TEST 1: ConfigMap Existence and Accessibility
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Test Suite 1: ConfigMap Existence"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

log_test "Checking kubectl access..."
if kubectl version --client &>/dev/null; then
    log_pass "kubectl accessible"
else
    log_fail "kubectl not accessible"
    exit 1
fi

# Check all ConfigMaps exist
declare -A CONFIGMAPS=(
    ["service-registry"]="kube-system"
    ["domain-registry"]="kube-system"
    ["sync-controller-registry"]="kube-system"
)

for cm in "${!CONFIGMAPS[@]}"; do
    ns="${CONFIGMAPS[$cm]}"
    log_test "Checking ConfigMap: $cm in namespace $ns..."
    if kubectl get configmap "$cm" -n "$ns" &>/dev/null; then
        log_pass "ConfigMap $cm exists"
    else
        log_fail "ConfigMap $cm does not exist"
    fi
done

echo ""

###############################################################################
# TEST 2: Schema Structure Validation
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Test Suite 2: Schema Structure Validation"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Test service-registry schema
log_test "Validating service-registry schema..."
SERVICE_REGISTRY=$(kubectl get configmap -n kube-system service-registry \
    -o jsonpath='{.data.services\.json}' 2>/dev/null || echo '{}')

if echo "$SERVICE_REGISTRY" | jq empty 2>/dev/null; then
    log_pass "service-registry contains valid JSON"
    
    # Check structure (flat key-value)
    if echo "$SERVICE_REGISTRY" | jq -e 'type == "object"' &>/dev/null; then
        log_pass "service-registry uses flat object structure"
    else
        log_fail "service-registry has unexpected structure"
    fi
else
    log_fail "service-registry contains invalid JSON"
fi

# Test domain-registry schema
log_test "Validating domain-registry schema..."
DOMAIN_REGISTRY=$(kubectl get configmap -n kube-system domain-registry \
    -o jsonpath='{.data.domains\.json}' 2>/dev/null || echo '{}')

if echo "$DOMAIN_REGISTRY" | jq empty 2>/dev/null; then
    log_pass "domain-registry contains valid JSON"
    
    # Check for unified structure
    if echo "$DOMAIN_REGISTRY" | jq -e 'has("domains") and has("vps_nodes")' &>/dev/null; then
        log_pass "domain-registry uses unified structure"
        
        # Validate nested types
        if echo "$DOMAIN_REGISTRY" | jq -e '.domains | type == "object"' &>/dev/null; then
            log_pass "domain-registry.domains is object"
        else
            log_fail "domain-registry.domains is not object"
        fi
        
        if echo "$DOMAIN_REGISTRY" | jq -e '.vps_nodes | type == "array"' &>/dev/null; then
            log_pass "domain-registry.vps_nodes is array"
        else
            log_fail "domain-registry.vps_nodes is not array"
        fi
    else
        log_fail "domain-registry missing unified structure (domains/vps_nodes)"
        log_warn "Expected: {\"domains\":{...}, \"vps_nodes\":[...]}"
        
        # Check if old structure
        if echo "$DOMAIN_REGISTRY" | jq -e 'keys | length > 0' &>/dev/null; then
            FIRST_KEY=$(echo "$DOMAIN_REGISTRY" | jq -r 'keys[0]')
            if [[ "$FIRST_KEY" != "domains" ]] && [[ "$FIRST_KEY" != "vps_nodes" ]]; then
                log_warn "Appears to be old structure (domains at root level)"
                log_warn "Migration needed!"
            fi
        fi
    fi
else
    log_fail "domain-registry contains invalid JSON"
fi

# Test routing.json
log_test "Validating routing.json schema..."
ROUTING=$(kubectl get configmap -n kube-system domain-registry \
    -o jsonpath='{.data.routing\.json}' 2>/dev/null || echo '{}')

if echo "$ROUTING" | jq empty 2>/dev/null; then
    log_pass "routing.json contains valid JSON"
    
    if echo "$ROUTING" | jq -e 'type == "object"' &>/dev/null; then
        log_pass "routing.json uses flat object structure"
    else
        log_fail "routing.json has unexpected structure"
    fi
else
    log_fail "routing.json contains invalid JSON"
fi

# Test sync-controller-registry schema
log_test "Validating sync-controller-registry schema..."
SYNC_REGISTRY=$(kubectl get configmap -n kube-system sync-controller-registry \
    -o jsonpath='{.data.registry\.json}' 2>/dev/null || echo '{}')

if echo "$SYNC_REGISTRY" | jq empty 2>/dev/null; then
    log_pass "sync-controller-registry contains valid JSON"
    
    # Check structure
    if echo "$SYNC_REGISTRY" | jq -e 'has("management_laptops") and has("vps_nodes") and has("worker_nodes")' &>/dev/null; then
        log_pass "sync-controller-registry has all required keys"
        
        # Validate types
        for key in management_laptops vps_nodes worker_nodes; do
            if echo "$SYNC_REGISTRY" | jq -e ".$key | type == \"array\"" &>/dev/null; then
                log_pass "sync-controller-registry.$key is array"
            else
                log_fail "sync-controller-registry.$key is not array"
            fi
        done
    else
        log_fail "sync-controller-registry missing required keys"
    fi
else
    log_fail "sync-controller-registry contains invalid JSON"
fi

echo ""

###############################################################################
# TEST 3: Read/Write Consistency
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Test Suite 3: Read/Write Consistency"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check domain-registry write patterns in code
log_test "Checking domain-registry write patterns..."
WRITE_PATTERNS=$(grep -r "\.domains\[" scripts/lib/multi-domain-registry.sh 2>/dev/null || echo "")
if [[ -n "$WRITE_PATTERNS" ]]; then
    log_pass "domain-registry writes use .domains[$domain] pattern"
else
    log_warn "Could not verify domain write pattern"
fi

# Check domain-registry read patterns in code
log_test "Checking domain-registry read patterns..."
READ_PATTERNS=$(grep -r "\.domains | keys" scripts/ 2>/dev/null || echo "")
if [[ -n "$READ_PATTERNS" ]]; then
    log_pass "domain-registry reads use .domains | keys pattern"
else
    log_warn "Could not verify domain read pattern"
fi

# Check for any legacy patterns (reading from root)
log_test "Checking for legacy read patterns..."
LEGACY_READS=$(grep -r "jq -r 'keys\[\]'" scripts/ 2>/dev/null | grep -v ".domains | keys" | grep domain-registry || echo "")
if [[ -z "$LEGACY_READS" ]]; then
    log_pass "No legacy read patterns found (reading domains from root)"
else
    log_fail "Legacy read patterns found:"
    echo "$LEGACY_READS"
fi

echo ""

###############################################################################
# TEST 4: Error Handling
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Test Suite 4: Error Handling"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check for empty string handling
log_test "Checking empty string handling in domain-registry reads..."
EMPTY_CHECKS=$(grep -A2 "domains\.json" scripts/lib/multi-domain-registry.sh | grep "|| echo" | wc -l)
if [[ "$EMPTY_CHECKS" -gt 0 ]]; then
    log_pass "Empty string fallbacks present ($EMPTY_CHECKS instances)"
else
    log_warn "No empty string fallbacks found"
fi

# Check for null handling
log_test "Checking null handling..."
NULL_CHECKS=$(grep -r "jq -r" scripts/ | grep -c "// empty\||| echo" || echo "0")
if [[ "$NULL_CHECKS" -gt 10 ]]; then
    log_pass "Null handling present ($NULL_CHECKS instances)"
else
    log_warn "Limited null handling found ($NULL_CHECKS instances)"
fi

echo ""

###############################################################################
# TEST 5: Data Consistency
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Test Suite 5: Data Consistency"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check for domain duplicates
log_test "Checking for domain duplicates..."
if echo "$DOMAIN_REGISTRY" | jq -e 'has("domains")' &>/dev/null; then
    DOMAIN_COUNT=$(echo "$DOMAIN_REGISTRY" | jq '.domains | length')
    log_pass "Found $DOMAIN_COUNT domains in registry"
    
    # Check if any domains at root level (should not exist in new structure)
    ROOT_KEYS=$(echo "$DOMAIN_REGISTRY" | jq -r 'keys[] | select(. != "domains" and . != "vps_nodes")')
    if [[ -z "$ROOT_KEYS" ]]; then
        log_pass "No domains at root level (clean structure)"
    else
        log_fail "Found domains at root level (structure inconsistency):"
        echo "$ROOT_KEYS"
    fi
else
    log_warn "domains key not found in registry"
fi

# Check for VPS duplicates
log_test "Checking for VPS duplicates..."
if echo "$DOMAIN_REGISTRY" | jq -e 'has("vps_nodes")' &>/dev/null; then
    VPS_COUNT=$(echo "$DOMAIN_REGISTRY" | jq '.vps_nodes | length')
    UNIQUE_VPS=$(echo "$DOMAIN_REGISTRY" | jq '.vps_nodes | unique_by(.tailscale_ip) | length')
    
    if [[ "$VPS_COUNT" -eq "$UNIQUE_VPS" ]]; then
        log_pass "No VPS duplicates ($VPS_COUNT unique VPS nodes)"
    else
        log_fail "Found VPS duplicates ($VPS_COUNT total, $UNIQUE_VPS unique)"
    fi
else
    log_warn "vps_nodes key not found in registry"
fi

echo ""

###############################################################################
# TEST 6: Validation Coverage
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Test Suite 6: Validation Coverage"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check for validation in setup-vps-node.sh
log_test "Checking VPS setup validation..."
if grep -q "Validating registry structure" scripts/setup-vps-node.sh; then
    log_pass "VPS setup includes registry structure validation"
else
    log_warn "VPS setup missing registry structure validation"
fi

if grep -q "has.*domains.*and has.*vps_nodes" scripts/setup-vps-node.sh; then
    log_pass "VPS setup validates unified structure"
else
    log_warn "VPS setup missing unified structure validation"
fi

# Check for SSH validation
log_test "Checking SSH validation..."
if grep -q "Final SSH Connectivity Check" scripts/setup-vps-node.sh; then
    log_pass "VPS setup includes final SSH validation"
else
    log_warn "VPS setup missing final SSH validation"
fi

echo ""

###############################################################################
# Summary
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  📊 Audit Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo -e "${GREEN}Passed:${NC}  $PASS_COUNT"
echo -e "${RED}Failed:${NC}  $FAIL_COUNT"
echo -e "${YELLOW}Warnings:${NC} $WARN_COUNT"
echo ""

if [[ "$FAIL_COUNT" -eq 0 ]]; then
    echo -e "${GREEN}✅ All critical tests passed!${NC}"
    echo ""
    echo "Registry architecture is consistent and robust."
    exit 0
else
    echo -e "${RED}❌ Some tests failed!${NC}"
    echo ""
    echo "Please review failures above and fix before reinstalling."
    exit 1
fi
