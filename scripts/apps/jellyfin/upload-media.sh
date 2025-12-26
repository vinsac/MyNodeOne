#!/bin/bash

###############################################################################
# Jellyfin - Media Upload Helper
# 
# Upload movies, TV shows, and music to Jellyfin media storage
###############################################################################

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

NAMESPACE="jellyfin"

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Upload Media to Jellyfin${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl not found${NC}"
    exit 1
fi

# Check if Jellyfin is running
if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
    echo -e "${RED}Error: Jellyfin is not installed${NC}"
    echo "Install first: sudo ./scripts/apps/jellyfin/install-jellyfin.sh"
    exit 1
fi

# Get Jellyfin pod
POD=$(kubectl get pod -n "$NAMESPACE" -l app=jellyfin -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$POD" ]; then
    echo -e "${RED}Error: Jellyfin pod not found${NC}"
    exit 1
fi

echo "📁 Jellyfin Media Storage Structure:"
echo ""
echo "The media directory is organized as:"
echo "  /media/Movies/     - For movies"
echo "  /media/TV/         - For TV shows"
echo "  /media/Music/      - For music"
echo "  /media/Photos/     - For photos"
echo ""

echo "🎬 What would you like to do?"
echo ""
echo "1. Upload a single file"
echo "2. Upload a folder"
echo "3. Show current media"
echo "4. Create directory structure"
echo "5. Exit"
echo ""
read -p "Choice [1-5]: " choice

case $choice in
    1)
        echo ""
        read -p "Enter path to file: " file_path
        
        if [ ! -f "$file_path" ]; then
            echo -e "${RED}Error: File not found: $file_path${NC}"
            exit 1
        fi
        
        echo ""
        echo "Select destination:"
        echo "1. Movies"
        echo "2. TV Shows"
        echo "3. Music"
        echo "4. Photos"
        echo "5. Custom path"
        echo ""
        read -p "Destination [1-5]: " dest_choice
        
        case $dest_choice in
            1) DEST_PATH="/media/Movies/" ;;
            2) DEST_PATH="/media/TV/" ;;
            3) DEST_PATH="/media/Music/" ;;
            4) DEST_PATH="/media/Photos/" ;;
            5) 
                read -p "Enter custom path (e.g., /media/Custom/): " DEST_PATH
                ;;
            *)
                echo "Invalid choice"
                exit 1
                ;;
        esac
        
        echo ""
        echo "📤 Uploading file..."
        kubectl exec -n "$NAMESPACE" "$POD" -- mkdir -p "$DEST_PATH"
        kubectl cp "$file_path" "$NAMESPACE/$POD:$DEST_PATH$(basename "$file_path")"
        
        echo -e "${GREEN}✓ File uploaded successfully!${NC}"
        echo "  Location: $DEST_PATH$(basename "$file_path")"
        ;;
        
    2)
        echo ""
        read -p "Enter path to folder: " folder_path
        
        if [ ! -d "$folder_path" ]; then
            echo -e "${RED}Error: Folder not found: $folder_path${NC}"
            exit 1
        fi
        
        echo ""
        echo "Select destination:"
        echo "1. Movies"
        echo "2. TV Shows"
        echo "3. Music"
        echo "4. Photos"
        echo "5. Custom path"
        echo ""
        read -p "Destination [1-5]: " dest_choice
        
        case $dest_choice in
            1) DEST_PATH="/media/Movies/" ;;
            2) DEST_PATH="/media/TV/" ;;
            3) DEST_PATH="/media/Music/" ;;
            4) DEST_PATH="/media/Photos/" ;;
            5) 
                read -p "Enter custom path (e.g., /media/Custom/): " DEST_PATH
                ;;
            *)
                echo "Invalid choice"
                exit 1
                ;;
        esac
        
        echo ""
        echo "📤 Uploading folder (this may take a while)..."
        kubectl exec -n "$NAMESPACE" "$POD" -- mkdir -p "$DEST_PATH"
        
        # Use tar to efficiently copy folder
        tar czf - -C "$(dirname "$folder_path")" "$(basename "$folder_path")" | \
            kubectl exec -i -n "$NAMESPACE" "$POD" -- tar xzf - -C "$DEST_PATH"
        
        echo -e "${GREEN}✓ Folder uploaded successfully!${NC}"
        echo "  Location: $DEST_PATH$(basename "$folder_path")"
        ;;
        
    3)
        echo ""
        echo "📁 Current media in Jellyfin:"
        echo ""
        kubectl exec -n "$NAMESPACE" "$POD" -- du -sh /media/* 2>/dev/null || \
            echo "No media found yet"
        echo ""
        echo "Detailed listing:"
        kubectl exec -n "$NAMESPACE" "$POD" -- ls -lh /media/ 2>/dev/null || \
            echo "Media directory is empty"
        ;;
        
    4)
        echo ""
        echo "📁 Creating standard directory structure..."
        kubectl exec -n "$NAMESPACE" "$POD" -- sh -c "
            mkdir -p /media/Movies
            mkdir -p /media/TV
            mkdir -p /media/Music
            mkdir -p /media/Photos
        "
        echo -e "${GREEN}✓ Directory structure created!${NC}"
        echo ""
        echo "Created:"
        echo "  /media/Movies/"
        echo "  /media/TV/"
        echo "  /media/Music/"
        echo "  /media/Photos/"
        ;;
        
    5)
        echo "Exiting."
        exit 0
        ;;
        
    *)
        echo "Invalid choice"
        exit 1
        ;;
esac

echo ""
echo "💡 Next steps:"
echo "  1. Go to Jellyfin web interface"
echo "  2. Dashboard → Libraries → Add Library"
echo "  3. Select content type (Movies, TV, etc.)"
echo "  4. Add folder: /media/Movies (or /media/TV, etc.)"
echo "  5. Jellyfin will scan and organize your media"
echo ""
echo "📖 For more options, see:"
echo "   scripts/apps/jellyfin/README.md"
echo ""
