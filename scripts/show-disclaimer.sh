#!/bin/bash

###############################################################################
# Legal Disclaimer Display
# Shows important legal information to users
###############################################################################

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
GREEN='\033[0;32m'
NC='\033[0m'

# Check if user has already accepted (this session)
DISCLAIMER_FILE="$HOME/.mynodeone/.disclaimer_accepted"

show_disclaimer() {
    clear
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}  ⚠️  IMPORTANT LEGAL DISCLAIMER  ⚠️${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${YELLOW}MyNodeOne - Open Source Software${NC}"
    echo ""
    echo -e "${RED}🔴 USE AT YOUR OWN RISK - NO WARRANTY PROVIDED${NC}"
    echo ""
    echo "By using this software, you acknowledge and agree that:"
    echo ""
    echo -e "${YELLOW}1. NO WARRANTY:${NC}"
    echo "   This software is provided \"AS IS\" without warranty of any kind."
    echo "   It may contain bugs, vulnerabilities, and security flaws."
    echo ""
    echo -e "${YELLOW}2. DATA LOSS RISK:${NC}"
    echo "   Using this software may result in COMPLETE DATA LOSS."
    echo "   You are solely responsible for maintaining backups."
    echo ""
    echo -e "${YELLOW}3. SECURITY VULNERABILITIES:${NC}"
    echo "   This software may have security vulnerabilities that could"
    echo "   lead to unauthorized access, data breaches, or system compromise."
    echo ""
    echo -e "${YELLOW}4. NO LIABILITY:${NC}"
    echo "   The authors assume NO responsibility for ANY damages"
    echo "   (direct, indirect, consequential, or otherwise) arising"
    echo "   from the use of this software."
    echo ""
    echo -e "${YELLOW}5. USER INDEMNIFICATION:${NC}"
    echo "   YOU AGREE TO FULLY INDEMNIFY AND HOLD HARMLESS the"
    echo "   repository owner, developers, and contributors from ALL"
    echo "   claims, damages, losses, and liabilities of any kind."
    echo ""
    echo -e "${YELLOW}6. MALICIOUS USE:${NC}"
    echo "   The authors disclaim ALL liability for illegal, malicious,"
    echo "   or unauthorized use of this software by any party."
    echo ""
    echo -e "${YELLOW}7. PRODUCTION USE:${NC}"
    echo "   Using this software in production environments is"
    echo "   AT YOUR OWN RISK with no guarantees of stability or uptime."
    echo ""
    echo -e "${YELLOW}8. JURISDICTION:${NC}"
    echo "   Any disputes must be resolved EXCLUSIVELY in the courts"
    echo "   of Toronto, Ontario, Canada."
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${GREEN}For complete legal terms, read:${NC}"
    echo "  • DISCLAIMER.md (comprehensive legal disclaimer)"
    echo "  • LICENSE (MIT License with additional terms)"
    echo ""
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# Check if running interactively
if [ -t 0 ]; then
    # Check if disclaimer was already accepted this session
    if [ ! -f "$DISCLAIMER_FILE" ]; then
        show_disclaimer
        
        echo -e "${YELLOW}Do you accept these terms and conditions?${NC}"
        echo ""
        read -p "Type 'I ACCEPT' to continue or anything else to exit: " response
        echo ""
        
        if [ "$response" = "I ACCEPT" ]; then
            # Create acceptance marker
            mkdir -p "$(dirname "$DISCLAIMER_FILE")"
            date > "$DISCLAIMER_FILE"
            echo -e "${GREEN}✓ Terms accepted. Continuing...${NC}"
            echo ""
            sleep 1
        else
            echo -e "${RED}Terms not accepted. Exiting.${NC}"
            echo ""
            echo "If you do not agree to these terms, you cannot use this software."
            echo ""
            exit 1
        fi
    fi
fi
