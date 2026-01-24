#!/bin/bash
# MyNodeOne Build Validation Script
# Validates all shell scripts for syntax errors before commit/push

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Counters
TOTAL_SCRIPTS=0
PASSED=0
FAILED=0

echo -e "${GREEN}🔍 MyNodeOne Build Validation${NC}"
echo "=================================="

# Find all shell scripts
SCRIPTS=$(find . -type f -name "*.sh" ! -path "./.git/*" ! -path "./node_modules/*" | sort)

if [ -z "$SCRIPTS" ]; then
    echo -e "${YELLOW}No shell scripts found${NC}"
    exit 0
fi

# Validate each script
for script in $SCRIPTS; do
    TOTAL_SCRIPTS=$((TOTAL_SCRIPTS + 1))
    echo -n "Validating $script... "
    
    if bash -n "$script" 2>/dev/null; then
        echo -e "${GREEN}✓${NC}"
        PASSED=$((PASSED + 1))
    else
        echo -e "${RED}✗${NC}"
        FAILED=$((FAILED + 1))
        echo -e "${RED}  Error in $script:${NC}"
        bash -n "$script" 2>&1 | sed 's/^/  /'
    fi
done

echo ""
echo "=================================="
echo -e "Total scripts: ${TOTAL_SCRIPTS}"
echo -e "${GREEN}Passed: ${PASSED}${NC}"
echo -e "${RED}Failed: ${FAILED}${NC}"

# Exit with error if any script failed
if [ $FAILED -gt 0 ]; then
    echo ""
    echo -e "${RED}❌ Build validation failed!${NC}"
    echo "Please fix the syntax errors above before committing."
    exit 1
else
    echo ""
    echo -e "${GREEN}✅ All scripts passed validation!${NC}"
    exit 0
fi
