# shellcheck shell=bash

# XQuartz setup for macOS — required for GUI apps in the container. Prompts to
# start (or install) XQuartz when not running. Caller is responsible for the
# `uname = Darwin` and CMD gating.
function ensure_xquartz() {
    if ! pgrep -xi "XQuartz" > /dev/null; then
        if [ -d "/Applications/Utilities/XQuartz.app" ]; then
            qecho "XQuartz is installed but not running."
            read -rp "Start XQuartz now? (y/n): " start_xquartz
            if [ "$start_xquartz" = "y" ]; then
                open -a XQuartz
                qecho "Waiting for XQuartz to start..."
                sleep 3
                xhost +localhost 2>/dev/null || echo "Run 'xhost +localhost' manually after XQuartz fully loads" 1>&2
            fi
        else
            echo "XQuartz is not installed. GUI apps require XQuartz on macOS."
            read -rp "Install XQuartz via Homebrew? (y/n): " install_xquartz
            if [ "$install_xquartz" = "y" ]; then
                brew install --cask xquartz
                echo "XQuartz installed. Please:"
                echo "  1. Open XQuartz"
                echo "  2. Go to Preferences > Security"
                echo "  3. Enable 'Allow connections from network clients'"
                echo "  4. Restart XQuartz"
                echo "  5. Run this script again"
                exit 0
            fi
        fi
    else
        # XQuartz is running, ensure xhost is configured
        xhost +localhost 2>/dev/null
    fi
}
