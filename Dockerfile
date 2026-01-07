FROM ubuntu:latest

ARG CLAUDE_CODE_VERSION=latest
ARG TOOL_CACHE_DIR
ARG HOST_ARCH
ARG HOST_HOME
ARG HOST_TZ
ARG GO_VERSION
ARG USERNAME=appuser
ARG USER_GROUP=appgroup
ARG GO_TAR
ARG GIT_DELTA_DEB
ARG NVM_INSTALL_SH
ARG BUN_INSTALL_SH
ARG ZSH_IN_DOCKER_SH

ENV TZ="$HOST_TZ"

# Install basic development tools and iptables/ipset
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
  sudo \
  unzip \
  vim \
  zsh \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /root

# Install latest go globally as root
COPY ${TOOL_CACHE_DIR}/${GO_TAR} /root/${GO_TAR}
RUN tar -xzf ${GO_TAR} -C /usr/local && rm ${GO_TAR}
RUN ln -s /usr/local/go/bin/go /usr/local/bin/go

COPY ${TOOL_CACHE_DIR}/${GIT_DELTA_DEB} /root/${GIT_DELTA_DEB}
RUN dpkg -i ${GIT_DELTA_DEB} && rm ${GIT_DELTA_DEB}

# Create a new non-root user and group
# -m ensures a home directory is created
RUN groupadd -r ${USER_GROUP} && useradd -r -g ${USER_GROUP} -m ${USERNAME}

# set up location location for absolute directory references
RUN mkdir -p ${HOST_HOME}/ && chown -R ${USERNAME}:${USER_GROUP} ${HOST_HOME}
RUN mkdir -p /commandhistory && chown -R ${USERNAME}:${USER_GROUP} /commandhistory

# Persist bash history.
RUN SNIPPET="export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  && touch /commandhistory/.bash_history \
  && chown -R $USERNAME /commandhistory

# Default powerline10k theme
COPY ${TOOL_CACHE_DIR}/${ZSH_IN_DOCKER_SH} /root/${ZSH_IN_DOCKER_SH}
RUN bash ${ZSH_IN_DOCKER_SH} -- \
  -p git \
  -p fzf \
  -a "source /usr/share/doc/fzf/examples/key-bindings.zsh" \
  -a "source /usr/share/doc/fzf/examples/completion.zsh" \
  -a "export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  -x

USER ${USERNAME}
WORKDIR /home/${USERNAME}

COPY ${TOOL_CACHE_DIR}/${NVM_INSTALL_SH} /home/${USERNAME}/${NVM_INSTALL_SH}
RUN bash ${NVM_INSTALL_SH} && rm ${NVM_INSTALL_SH}
RUN bash -c "source /home/${USERNAME}/.nvm/nvm.sh && nvm install --lts"

COPY ${TOOL_CACHE_DIR}/${BUN_INSTALL_SH} /home/${USERNAME}/${BUN_INSTALL_SH}
RUN bash ${BUN_INSTALL_SH} && rm ${BUN_INSTALL_SH}

# Set `DEVCONTAINER` environment variable to help with orientation
ENV DEVCONTAINER=true

# Create workspace directory and set permissions
RUN mkdir -p /home/${USERNAME}/workspace

# Create host home directory structure for absolute path compatibility
# This allows plugins with absolute paths to resolve correctly
RUN ln -s /home/${USERNAME}/.claude ${HOST_HOME}/.claude && \
  ln -s /home/${USERNAME}/.claude-mem ${HOST_HOME}/.claude-mem && \
  ln -s /home/${USERNAME}/workspace ${HOST_HOME}/playground

WORKDIR /home/${USERNAME}/workspace

# Install global packages
# ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
#ENV PATH=$PATH:/usr/local/share/npm-global/bin

# Set the default shell to zsh rather than sh
ENV SHELL=/bin/zsh

# Set the default editor and visual
ENV EDITOR=vim
ENV VISUAL=vim

# Install Claude
RUN /home/${USERNAME}/.bun/bin/bun install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# Copy and set up firewall script
COPY init-firewall.sh /usr/local/bin/
USER root
RUN chmod +x /usr/local/bin/init-firewall.sh && \
  echo "node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/node-firewall && \
  chmod 0440 /etc/sudoers.d/node-firewall

USER ${USERNAME}

RUN echo "export PATH=\$PATH:/home/${USERNAME}/.bun/bin" >> /home/${USERNAME}/.zshenv
RUN echo "PROMPT='%F{red}%~%f %# '" >> /home/${USERNAME}/.zshrc
RUN echo "source /home/${USERNAME}/.nvm/nvm.sh" >> /home/${USERNAME}/.zshrc

CMD ["/bin/zsh"]