FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive CC=gcc-12 CXX=g++-12
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc-12 g++-12 build-essential ninja-build cmake pkg-config \
    autoconf automake libtool ca-certificates curl file python3 git \
    libgl1-mesa-dev libopengl-dev libegl1-mesa-dev \
    libluajit-5.1-dev luajit libopenal-dev libmodplug-dev libvorbis-dev \
    libtheora-dev libfreetype6-dev libmpg123-dev zlib1g-dev \
    libasound2-dev libpulse-dev libudev-dev libdbus-1-dev \
    libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxi-dev \
    libxinerama-dev libxss-dev libxkbcommon-dev libwayland-dev \
    wayland-protocols libdrm-dev libgbm-dev xvfb xauth mesa-utils \
    && rm -rf /var/lib/apt/lists/*
COPY sources/ /tmp/sources/
RUN cd /tmp/sources && sha256sum -c SHA256SUMS \
    && test "$(uname -m)" = aarch64 \
    && tar -xzf SDL2-2.30.11.tar.gz \
    && cmake -S SDL2-2.30.11 -B sdl-build -GNinja -DCMAKE_BUILD_TYPE=Release -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TEST=OFF \
    && cmake --build sdl-build -j6 && cmake --install sdl-build \
    && tar -xzf openxr-1.1.63.tar.gz \
    && cmake -S OpenXR-SDK-release-1.1.63 -B xr-build -GNinja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/openxr -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DDYNAMIC_LOADER=OFF -DBUILD_API_LAYERS=OFF -DBUILD_TESTS=OFF -DBUILD_CONFORMANCE_TESTS=OFF -DBUILD_WITH_SYSTEM_JSONCPP=OFF -DBUILD_WITH_XCB_HEADERS=OFF -DBUILD_WITH_WAYLAND_HEADERS=OFF \
    && cmake --build xr-build -j6 && cmake --install xr-build \
    && tar -xzf openal-soft-1.23.1.tar.gz \
    && cmake -S openal-soft-1.23.1 -B al-build -GNinja -DCMAKE_BUILD_TYPE=Release -DALSOFT_UTILS=OFF -DALSOFT_EXAMPLES=OFF -DALSOFT_BACKEND_SNDIO=OFF \
    && cmake --build al-build -j6 && cmake --install al-build \
    && tar -xjf libtheora-1.1.1.tar.bz2 && cd libtheora-1.1.1 \
    && cp /usr/share/misc/config.guess /usr/share/misc/config.sub . \
    && ./configure --prefix=/usr/local --disable-examples --disable-static && make -j6 && make install \
    && cd /tmp/sources && tar -xjf mpg123-1.32.10.tar.bz2 && cd mpg123-1.32.10 \
    && ./configure --prefix=/usr/local --disable-static && make -j6 && make install \
    && cd /tmp/sources && tar -xzf love-11.5-linux-src.tar.gz \
    && mv love-11.5 /opt/love-11.5 && cd /opt/love-11.5 \
    && ./configure --prefix=/opt/love --with-lua=luajit CXXFLAGS='-O2 -fsigned-char -ffp-contract=off' CPPFLAGS='-I/usr/local/include' LDFLAGS='-L/usr/local/lib' \
    && make -j6 && make install && ldconfig \
    && mkdir -p /opt/runtime-licenses \
    && cp /tmp/sources/SDL2-2.30.11/LICENSE.txt /opt/runtime-licenses/SDL2.txt \
    && cp /tmp/sources/OpenXR-SDK-release-1.1.63/LICENSE /opt/runtime-licenses/OpenXR.txt \
    && cp /tmp/sources/openal-soft-1.23.1/COPYING /opt/runtime-licenses/OpenAL.txt \
    && cp /tmp/sources/libtheora-1.1.1/COPYING /opt/runtime-licenses/Theora.txt \
    && cp /tmp/sources/mpg123-1.32.10/COPYING /opt/runtime-licenses/mpg123.txt \
    && rm -rf /tmp/sources
ENV PATH=/opt/love/bin:$PATH LD_LIBRARY_PATH=/opt/love/lib:/usr/local/lib
WORKDIR /src
