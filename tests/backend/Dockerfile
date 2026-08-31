# The ucode compiler used by the ci.yml "ucode syntax" gate, baked into an
# image so the exact same binary (pinned version v0.0.20250529, fs + math
# modules only) is available locally for every chunk of the backend work.
#
# The apt layer and the ucode build are cached by docker's layer cache: only
# the first `docker build` downloads packages and compiles ucode. Every later
# run reuses the image.

FROM debian:bookworm

RUN apt-get update -qq \
 && apt-get install -y -qq build-essential cmake libjson-c-dev pkg-config git

RUN git clone --depth 1 -b v0.0.20250529 https://github.com/jow-/ucode /opt/ucode/src

RUN cmake -S /opt/ucode/src -B /opt/ucode/build -DCMAKE_BUILD_TYPE=Release \
      -DFS_SUPPORT=ON -DMATH_SUPPORT=ON \
      -DUBUS_SUPPORT=OFF -DUCI_SUPPORT=OFF -DRTNL_SUPPORT=OFF \
      -DNL80211_SUPPORT=OFF -DRESOLV_SUPPORT=OFF -DLOG_SUPPORT=OFF \
      -DDEBUG_SUPPORT=OFF \
 && cmake --build /opt/ucode/build -j"$(nproc)"
