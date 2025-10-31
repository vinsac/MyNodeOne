#!/bin/bash

###############################################################################
# MyNodeOne App Store
# 
# Interactive menu for one-click app installation
# Makes it easy for non-technical users to install popular apps
###############################################################################

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_DIR="$SCRIPT_DIR/apps"

clear

echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║                                                                   ║${NC}"
echo -e "${CYAN}║           ${MAGENTA}MyNodeOne App Store${CYAN}                                   ║${NC}"
echo -e "${CYAN}║           ${NC}One-Click Application Installation${CYAN}                    ║${NC}"
echo -e "${CYAN}║                                                                   ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl not found. Please install Kubernetes first.${NC}"
    exit 1
fi

if ! kubectl get nodes &> /dev/null; then
    echo -e "${RED}Error: Cannot connect to Kubernetes cluster.${NC}"
    exit 1
fi

show_menu() {
    echo ""
    echo -e "${BLUE}╭─────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "${BLUE}│${NC}  ${GREEN}Media & Entertainment${NC}                                          ${BLUE}│${NC}"
    echo -e "${BLUE}│${NC}    ${YELLOW}1.${NC} Jellyfin        - Media server (Netflix-like)              ${BLUE}│${NC}"
    echo -e "${BLUE}│${NC}    ${YELLOW}2.${NC} Plex            - Premium media server                     ${BLUE}│${NC}"
    echo -e "${BLUE}│${NC}    ${YELLOW}3.${NC} Audiobookshelf  - Audiobooks & podcasts ${CYAN}[Coming Soon]${NC}     ${BLUE}│${NC}"
    echo -e "${BLUE}│${NC}    ${YELLOW}4.${NC} Minecraft       - Game server                              ${BLUE}│${NC}"
    echo -e "${BLUE}╰─────────────────────────────────────────────────────────────────╯${NC}"
    echo ""
    echo -e "${BLUE}╭─────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "${BLUE}│${NC}  ${GREEN}Photos & Files${NC}                                                 ${BLUE}│${NC}"
    echo -e "${BLUE}│${NC}    ${YELLOW}5.${NC} Immich          - Google Photos alternative                ${BLUE}│${NC}"
    echo -e "${BLUE}│${NC}    ${YELLOW}6.${NC} Nextcloud       - Cloud storage platform ${CYAN}[Coming Soon]${NC}    ${BLUE}│${NC}"
    echo -e "${BLUE}│${NC}    ${YELLOW}7.${NC} Paperless-ngx   - Document management ${CYAN}[Coming Soon]${NC}       ${BLUE}│${NC}"
    echo -e "${BLUE}╰─────────────────────────────────────────────────────────────────╯${NC}"
    echo ""
    echo -e "${BLUE}╭─────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "${BLUE}│${NC}  ${GREEN}Communication & Productivity${NC}                                  ${BLUE}│${NC}"
    echo -e "${BLUE}│${NC}    ${YELLOW}8.${NC} Mattermost      - Team chat (Slack) ${CYAN}[Coming Soon]${NC}        ${BLUE}│${NC}"
    echo -e "${BLUE}│${NC}    ${YELLOW}9.${NC} Gitea           - Git server (GitHub) ${CYAN}[Coming Soon]${NC}      ${BLUE}│${NC}"
    echo -e "${BLUE}╰─────────────────────────────────────────────────────────────────╯${NC}"
    echo ""
    echo -e "${BLUE}╭─────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "${BLUE}│${NC}  ${GREEN}Security & Monitoring${NC}                                         ${BLUE}│${NC}"
    echo -e "${BLUE}│${NC}    ${YELLOW}10.${NC} Vaultwarden    - Password manager                         ${BLUE}│${NC}"
    echo -e "${BLUE}│${NC}    ${YELLOW}11.${NC} Uptime Kuma    - Monitoring tool ${CYAN}[Coming Soon]${NC}          ${BLUE}│${NC}"
    echo -e "${BLUE}│${NC}    ${YELLOW}12.${NC} Homepage       - Application dashboard                    ${BLUE}│${NC}"
    echo -e "${BLUE}╰─────────────────────────────────────────────────────────────────╯${NC}"
    echo ""
    echo -e "${BLUE}╭─────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "${BLUE}│${NC}  ${GREEN}Utilities${NC}                                                      ${BLUE}│${NC}"
    echo -e "${BLUE}│${NC}    ${YELLOW}13.${NC} List Installed Apps                                      ${BLUE}│${NC}"
    echo -e "${BLUE}│${NC}    ${YELLOW}14.${NC} View App Access Info                                     ${BLUE}│${NC}"
    echo -e "${BLUE}│${NC}    ${YELLOW}0.${NC}  Exit                                                     ${BLUE}│${NC}"
    echo -e "${BLUE}╰─────────────────────────────────────────────────────────────────╯${NC}"
    echo ""
}

list_installed_apps() {
    echo ""
    echo -e "${GREEN}Installed Applications:${NC}"
    echo ""
    
    # List all namespaces that contain apps
    kubectl get namespaces -o json | \
        jq -r '.items[].metadata.name' | \
        grep -E "jellyfin|immich|vaultwarden|minecraft|homepage|plex|nextcloud|mattermost|gitea|uptime|paperless|audiobookshelf" || \
        echo "No apps installed yet"
    
    echo ""
}

view_app_info() {
    echo ""
    echo -e "${GREEN}Application Access Information:${NC}"
    echo ""
    
    # Get LoadBalancer IPs for all app services
    for ns in $(kubectl get namespaces -o json | jq -r '.items[].metadata.name' | grep -E "jellyfin|immich|vaultwarden|minecraft|homepage"); do
        echo -e "${YELLOW}$ns:${NC}"
        kubectl get svc -n "$ns" -o wide 2>/dev/null | grep LoadBalancer || echo "  No LoadBalancer service found"
        echo ""
    done
}

install_app() {
    local app_name=$1
    local script_path="$APPS_DIR/install-${app_name}.sh"
    
    if [ ! -f "$script_path" ]; then
        echo -e "${RED}Error: Installation script not found: $script_path${NC}"
        return 1
    fi
    
    if [ ! -x "$script_path" ]; then
        chmod +x "$script_path"
    fi
    
    echo ""
    echo -e "${CYAN}Installing $app_name...${NC}"
    echo ""
    
    bash "$script_path"
    
    echo ""
    echo -e "${GREEN}Press Enter to continue...${NC}"
    read
}

while true; do
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║           ${MAGENTA}MyNodeOne App Store${CYAN}                                   ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    
    show_menu
    
    echo -ne "${CYAN}Select an option [0-14]: ${NC}"
    read choice
    
    case $choice in
        1)
            install_app "jellyfin"
            ;;
        2)
            install_app "plex"
            ;;
        3)
            install_app "audiobookshelf"
            ;;
        4)
            install_app "minecraft"
            ;;
        5)
            install_app "immich"
            ;;
        6)
            install_app "nextcloud"
            ;;
        7)
            install_app "paperless"
            ;;
        8)
            install_app "mattermost"
            ;;
        9)
            install_app "gitea"
            ;;
        10)
            install_app "vaultwarden"
            ;;
        11)
            install_app "uptime-kuma"
            ;;
        12)
            install_app "homepage"
            ;;
        13)
            list_installed_apps
            echo -e "${GREEN}Press Enter to continue...${NC}"
            read
            ;;
        14)
            view_app_info
            echo -e "${GREEN}Press Enter to continue...${NC}"
            read
            ;;
        0)
            echo ""
            echo -e "${GREEN}Thank you for using MyNodeOne App Store!${NC}"
            echo ""
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid option. Please try again.${NC}"
            sleep 2
            ;;
    esac
done
