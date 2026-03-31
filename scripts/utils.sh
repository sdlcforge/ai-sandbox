export QUIET=1 # default  will be set later

# --- Function definitions (testable via Include) ---

function qecho() {
    [ ${QUIET} -ne 0 ] && echo "$@" || true
}