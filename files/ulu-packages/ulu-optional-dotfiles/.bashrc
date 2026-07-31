#
# ~/.bashrc
#

# If not running interactively, don't do anything
[[ $- != *i* ]] && return

# alias ls='ls --color=auto'
# alias grep='grep --color=auto'
# PS1='[\u@\h \W]\$ '

export CC="ccache gcc"
export CXX="ccache g++"
export CCACHE_SLOPPINESS=file_macro,locale,time_macros
export CCACHE_COMPRESS=1
export CCACHE_COMPRESSLEVEL=6

# Compiler optimization
export CFLAGS="-march=native -O2 -pipe"
export CXXFLAGS="$CFLAGS"

# Parallel builds (auto detect cores)
export MAKEFLAGS="-j$(nproc)"
