#!/bin/bash
# The Ads Machine — One-line installer
# curl -fsSL https://raw.githubusercontent.com/seancrowe01/ads-machine/main/install.sh | bash

set -e

REPO="https://github.com/seancrowe01/ads-machine.git"
DIR="ads-machine"

echo ""
echo "  ╔══════════════════════════════════╗"
echo "  ║       THE ADS MACHINE            ║"
echo "  ║  Closed-Loop Ad Intelligence     ║"
echo "  ╚══════════════════════════════════╝"
echo ""

# Check for git
if ! command -v git &> /dev/null; then
    echo "Error: git is not installed. Install git first."
    exit 1
fi

# Clone
if [ -d "$DIR" ]; then
    echo "Directory '$DIR' already exists. Pulling latest..."
    cd "$DIR" && git pull origin main
else
    echo "Cloning repo..."
    git clone "$REPO" "$DIR"
    cd "$DIR"
fi

# Copy .env
if [ ! -f ".env" ]; then
    cp .env.example .env
    echo "Created .env from template."
else
    echo ".env already exists. Skipping."
fi

echo ""
echo "  ✓ Installed to $(pwd)"
echo ""
echo "  Next steps:"
echo ""
echo "  1. Open .env and add your API keys:"
echo "     - AIRTABLE_API_KEY  (https://airtable.com/create/tokens)"
echo "     - RELEVANCE_API_KEY (Relevance AI key - powers Ad Library scraping)"
echo "     - RELEVANCE_PROJECT (your Relevance AI project id)"
echo ""
echo "     No Apify account is needed."
echo ""
echo "  2. Open Claude Code in this folder and run:"
echo "     /ads-setup"
echo ""
echo "  That's it. The setup wizard handles the rest."
echo ""
