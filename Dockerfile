FROM ubuntu:latest

# === LAYER 1: Base packages (no ARGs, most stable) ===
RUN apt-get update && apt-get install -y --no-install-recommends \
  aggregate \
  ca-certificates \
  curl \
  dnsutils \
  fzf \
  gh \
  git \
  gnupg2 \
  iproute2 \
  ipset \
  iptables \
  jq \
  less \
  man-db \
  procps \
  ssh \
  sudo \
  unzip \
  vim \
  zsh \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# === LAYER 2: Timezone (rarely changes) ===
ARG HOST_TZ
ENV TZ="$HOST_TZ"
ARG SSH_AUTH_SOCK
ENV SSH_AUTH_SOCK="$SSH_AUTH_SOCK"

WORKDIR /root

# === LAYER 3: Go installation ===
ARG TOOL_CACHE_DIR
ARG GO_TAR
COPY ${TOOL_CACHE_DIR}/${GO_TAR} /root/${GO_TAR}
RUN tar -xzf ${GO_TAR} -C /usr/local && rm ${GO_TAR}
RUN ln -s /usr/local/go/bin/go /usr/local/bin/go

# === LAYER 4: Git Delta ===
ARG GIT_DELTA_DEB
COPY ${TOOL_CACHE_DIR}/${GIT_DELTA_DEB} /root/${GIT_DELTA_DEB}
RUN dpkg -i ${GIT_DELTA_DEB} && rm ${GIT_DELTA_DEB}

# === LAYER 5: Zsh-in-docker (root setup) ===
ARG ZSH_IN_DOCKER_SH
COPY ${TOOL_CACHE_DIR}/${ZSH_IN_DOCKER_SH} /root/${ZSH_IN_DOCKER_SH}
RUN bash ${ZSH_IN_DOCKER_SH} -- \
  -p git \
  -p fzf \
  -a "source /usr/share/doc/fzf/examples/key-bindings.zsh" \
  -a "source /usr/share/doc/fzf/examples/completion.zsh" \
  -a "export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  -x

# === LAYER 6: User creation (changes per machine) ===
ARG HOST_USER
ENV HOST_USER=${HOST_USER}
ARG HOST_HOME
RUN groupadd -r ${HOST_USER} && useradd -r -g ${HOST_USER} -d ${HOST_HOME} -m ${HOST_USER}
RUN mkdir -p /commandhistory && chown -R ${HOST_USER}:${HOST_USER} /commandhistory
RUN touch /commandhistory/.bash_history && chown -R ${HOST_USER} /commandhistory

USER ${HOST_USER}
WORKDIR ${HOST_HOME}

# === LAYER 7: NVM + Node ===
ARG NVM_INSTALL_SH
COPY ${TOOL_CACHE_DIR}/${NVM_INSTALL_SH} ${HOST_HOME}/${NVM_INSTALL_SH}
RUN bash ${NVM_INSTALL_SH} && rm ${NVM_INSTALL_SH}
RUN bash -c "source ${HOST_HOME}/.nvm/nvm.sh && nvm install --lts"

# === LAYER 8: Bun ===
ARG BUN_INSTALL_SH
COPY ${TOOL_CACHE_DIR}/${BUN_INSTALL_SH} ${HOST_HOME}/${BUN_INSTALL_SH}
RUN bash ${BUN_INSTALL_SH} && rm ${BUN_INSTALL_SH}

# === LAYER 9: Workspace & environment setup ===
RUN mkdir -p ${HOST_HOME}/playground
ENV DEVCONTAINER=true
ENV SHELL=/bin/zsh
ENV EDITOR=vim
ENV VISUAL=vim

WORKDIR ${HOST_HOME}/playground

# === LAYER 10: Claude Code (changes most frequently) ===
ARG CLAUDE_CODE_VERSION=latest
RUN ${HOST_HOME}/.bun/bin/bun install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# === LAYER 11: Firewall setup (root) ===
COPY init-firewall.sh /usr/local/bin/
USER root
RUN chmod +x /usr/local/bin/init-firewall.sh && \
  echo "node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/node-firewall && \
  chmod 0440 /etc/sudoers.d/node-firewall

# === LAYER 11.b: Allow the user to sudo entrypoint script without a password ===
RUN usermod -aG sudo ${HOST_USER}
# RUN echo >> /etc/sudoers
# RUN echo '${HOST_USER} ALL=(ALL) NOPASSWD: /entrypoint.sh' >> /etc/sudoers
# DEBUG
RUN chmod a+r /etc/sudoers
# RUN echo "#includedir /etc/sudoers.d" >> /etc/sudoers
# RUN echo "${HOST_USER} ALL=(ALL) NOPASSWD: /entrypoint.sh" >> /etc/sudoers.d/entrypoint_script
RUN echo "${HOST_USER} ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers.d/entrypoint_script
#RUN chmod 0440 /etc/sudoers.d/entrypoint_script

# === LAYER 12: Shell config ===
USER ${HOST_USER}
RUN echo "export PATH=\$PATH:${HOST_HOME}/.bun/bin:${HOST_HOME}/.local/bin" >> ${HOST_HOME}/.zshenv
RUN echo "PROMPT='%F{red}%~%f %# '" >> ${HOST_HOME}/.zshrc
RUN echo "source ${HOST_HOME}/.nvm/nvm.sh" >> ${HOST_HOME}/.zshrc

# === LAYER 12b: Git config ===
ARG GIT_USER_NAME
ARG GIT_USER_EMAIL
RUN git config --global user.name "${GIT_USER_NAME}" && \
    git config --global user.email "${GIT_USER_EMAIL}"

# === LAYER 13: Copy claude.json (may change often) ===
COPY ${TOOL_CACHE_DIR}/.claude.json ${HOST_HOME}/.claude.json

ENTRYPOINT ["/usr/bin/sudo", "-E", "/entrypoint.sh"]
CMD ["/bin/zsh"]
