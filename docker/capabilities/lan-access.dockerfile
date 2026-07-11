# === CAPABILITY: lan-access ===
# This fragment is appended by docker/scripts/assemble-dockerfile.sh when the
# "lan-access" capability is selected by a profile. It is intentionally
# empty (no RUN/COPY/etc.) -- "lan-access" only affects container *runtime*
# firewall behavior (see docker/init-firewall.sh's capability-dispatch
# block), not the built image. The fragment still has to exist because
# assemble-dockerfile.sh validates that every capability in a profile's
# resolved capabilities list has a matching
# docker/capabilities/<name>.dockerfile fragment, and errors otherwise; see
# plan/phase-02-network-capabilities/001-*.md.
